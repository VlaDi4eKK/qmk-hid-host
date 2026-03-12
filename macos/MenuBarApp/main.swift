import AppKit
import Carbon
import Darwin

private enum StatusVisualState: Hashable {
    case connected
    case problem
}

private struct KeyboardDeviceDefinition {
    let name: String?
    let productId: String
    let usage: Int?
    let usagePage: Int?

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "productId": productId,
        ]

        if let name {
            object["name"] = name
        }
        if let usage {
            object["usage"] = usage
        }
        if let usagePage {
            object["usagePage"] = usagePage
        }

        return object
    }
}

private struct KeyboardRevision {
    let name: String
    let matchers: [KeyboardMatcher]
    let devices: [KeyboardDeviceDefinition]
}

private struct KeyboardModel {
    let name: String
    let revisions: [KeyboardRevision]
}

private struct KeyboardVendor {
    let name: String
    let models: [KeyboardModel]
}

private struct SystemLayout {
    let code: String
    let localizedName: String
}

private struct KeyboardMatcher {
    let vendorId: String?
    let productId: String?
    let productName: String?
    let productNameContains: String?

    func matches(_ device: DetectedHIDDevice) -> Bool {
        if let vendorId, normalizeHex(vendorId) != normalizeHex(device.vendorId) {
            return false
        }

        if let productId, normalizeHex(productId) != normalizeHex(device.productId) {
            return false
        }

        if let productName, productName != device.productName {
            return false
        }

        if let productNameContains, !device.productName.localizedCaseInsensitiveContains(productNameContains) {
            return false
        }

        return true
    }
}

private struct DetectedHIDDevice {
    let vendorId: String
    let productId: String
    let usagePage: Int?
    let usage: Int?
    let productName: String
    let rawLine: String

    var fallbackConfigObject: [String: Any] {
        var object: [String: Any] = [
            "productId": productId,
        ]

        if !productName.isEmpty {
            object["name"] = productName
        }

        return object
    }
}

private struct KeyboardCatalogFile: Decodable {
    let vendors: [KeyboardVendor]
}

extension KeyboardVendor: Decodable {}
extension KeyboardModel: Decodable {}
extension KeyboardRevision: Decodable {}
extension KeyboardDeviceDefinition: Decodable {}
extension KeyboardMatcher: Decodable {}

private func normalizeHex(_ value: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.hasPrefix("0x") ? String(normalized.dropFirst(2)) : normalized
}

private func loadKeyboardCatalog() -> [KeyboardVendor] {
    guard
        let url = Bundle.main.url(forResource: "KeyboardCatalog", withExtension: "json"),
        let data = try? Data(contentsOf: url),
        let catalog = try? JSONDecoder().decode(KeyboardCatalogFile.self, from: data)
    else {
        return []
    }

    return catalog.vendors
}

private func defaultConfigObject() -> [String: Any] {
    [
        "devices": [
            [
                "name": "stront",
                "productId": "0x0844",
            ],
        ],
        "layouts": ["en"],
    ]
}

private func formattedJSONString(from object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    guard var formattedText = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "QMKHIDHost", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to render formatted JSON."])
    }

    formattedText.append("\n")
    return formattedText
}

private final class ConfigEditorWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        let selector: Selector? = switch (characters, flags) {
        case ("x", [.command]):
            #selector(NSText.cut(_:))
        case ("c", [.command]):
            #selector(NSText.copy(_:))
        case ("v", [.command]):
            #selector(NSText.paste(_:))
        case ("a", [.command]):
            #selector(NSText.selectAll(_:))
        case ("z", [.command]):
            Selector(("undo:"))
        case ("z", [.command, .shift]):
            Selector(("redo:"))
        default:
            nil
        }

        if let selector, NSApp.sendAction(selector, to: nil, from: self) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

private func preferredSystemLayoutOrderTokens() -> [String] {
    guard
        let defaults = UserDefaults(suiteName: "com.apple.HIToolbox"),
        let inputSources = defaults.array(forKey: "AppleEnabledInputSources")
    else {
        return []
    }

    return inputSources.compactMap { source in
        guard
            let dictionary = source as? [String: Any],
            (dictionary["InputSourceKind"] as? String) == "Keyboard Layout"
        else {
            return nil
        }

        if let inputSourceID = dictionary["InputSourceID"] as? String {
            return inputSourceID.split(separator: ".").last.map(String.init) ?? inputSourceID
        }

        if let keyboardLayoutName = dictionary["KeyboardLayout Name"] as? String {
            return keyboardLayoutName
        }

        return nil
    }
}

private func availableSystemLayouts() -> [SystemLayout] {
    let inputSources = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
    var layouts: [SystemLayout] = []
    var seenCodes = Set<String>()

    for case let inputSource as TISInputSource in inputSources {
        guard stringProperty(for: inputSource, key: kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String) else {
            continue
        }

        if let isEnabled = boolProperty(for: inputSource, key: kTISPropertyInputSourceIsEnabled), !isEnabled {
            continue
        }

        if let isSelectCapable = boolProperty(for: inputSource, key: kTISPropertyInputSourceIsSelectCapable), !isSelectCapable {
            continue
        }

        guard
            let inputSourceID = stringProperty(for: inputSource, key: kTISPropertyInputSourceID),
            let localizedName = stringProperty(for: inputSource, key: kTISPropertyLocalizedName)
        else {
            continue
        }

        let code = inputSourceID.split(separator: ".").last.map(String.init) ?? inputSourceID
        if seenCodes.insert(code).inserted {
            layouts.append(SystemLayout(code: code, localizedName: localizedName))
        }
    }

    let preferredOrderTokens = preferredSystemLayoutOrderTokens()
    guard !preferredOrderTokens.isEmpty else {
        return layouts
    }

    var remainingLayouts = layouts
    var orderedLayouts: [SystemLayout] = []
    for token in preferredOrderTokens {
        if let index = remainingLayouts.firstIndex(where: { $0.code == token || $0.localizedName == token }) {
            orderedLayouts.append(remainingLayouts.remove(at: index))
        }
    }

    orderedLayouts.append(contentsOf: remainingLayouts)
    return orderedLayouts
}

private func parseDetectedHIDDevices(from output: String) -> [DetectedHIDDevice] {
    let cleanedOutput = output.replacingOccurrences(
        of: #"\u{001B}\[[0-9;]*m"#,
        with: "",
        options: .regularExpression
    )

    let pattern = #"HID: VID=([0-9A-Fa-f]+), PID=([0-9A-Fa-f]+), usage_page=([^,]+), usage=([^,]+), productId=(0x[0-9A-Fa-f]+) product="([^"]*)""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }

    let nsOutput = cleanedOutput as NSString
    let matches = regex.matches(in: cleanedOutput, range: NSRange(location: 0, length: nsOutput.length))
    return matches.compactMap { match in
        guard match.numberOfRanges >= 7 else {
            return nil
        }

        let vendorId = nsOutput.substring(with: match.range(at: 1))
        let usagePage = Int(nsOutput.substring(with: match.range(at: 3)))
        let usage = Int(nsOutput.substring(with: match.range(at: 4)))
        let productId = nsOutput.substring(with: match.range(at: 5))
        let productName = nsOutput.substring(with: match.range(at: 6))

        return DetectedHIDDevice(
            vendorId: "0x\(vendorId.lowercased())",
            productId: productId.lowercased(),
            usagePage: usagePage,
            usage: usage,
            productName: productName,
            rawLine: nsOutput.substring(with: match.range)
        )
    }
}

private func matchedCatalogSelection(
    in keyboardCatalog: [KeyboardVendor],
    for devices: [DetectedHIDDevice]
) -> (vendor: Int, model: Int, revision: Int, device: DetectedHIDDevice)? {
    for (vendorIndex, vendor) in keyboardCatalog.enumerated() {
        for (modelIndex, model) in vendor.models.enumerated() {
            for (revisionIndex, revision) in model.revisions.enumerated() {
                for device in devices where revision.matchers.contains(where: { $0.matches(device) }) {
                    return (vendorIndex, modelIndex, revisionIndex, device)
                }
            }
        }
    }

    return nil
}

private func runProcess(executableURL: URL, arguments: [String], environment: [String: String] = [:]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    var mergedEnvironment = ProcessInfo.processInfo.environment
    for (key, value) in environment {
        mergedEnvironment[key] = value
    }

    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = mergedEnvironment
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: data, as: UTF8.self)

    guard process.terminationStatus == 0 else {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        throw NSError(
            domain: "QMKHIDHost",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Process exited with status \(process.terminationStatus)." : message]
        )
    }

    return output
}

private func stringProperty(for inputSource: TISInputSource, key: CFString) -> String? {
    guard let property = TISGetInputSourceProperty(inputSource, key) else {
        return nil
    }

    let value = Unmanaged<CFTypeRef>.fromOpaque(property).takeUnretainedValue()
    return value as? String
}

private func boolProperty(for inputSource: TISInputSource, key: CFString) -> Bool? {
    guard let property = TISGetInputSourceProperty(inputSource, key) else {
        return nil
    }

    let value = Unmanaged<CFTypeRef>.fromOpaque(property).takeUnretainedValue()
    return (value as? NSNumber)?.boolValue
}

@main
struct QMKHIDHostMenuBarMain {
    private static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let fileManager = FileManager.default
    private let launchAgentLabel = "com.zzeneg.qmk-hid-host.login-item"
    private let keyboardCatalog = loadKeyboardCatalog()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let stateMenuItem = NSMenuItem(title: "Launching...", action: nil, keyEquivalent: "")
    private lazy var launchAtLoginMenuItem = makeMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin))
    private var hostProcess: Process?
    private var hostOutputPipe: Pipe?
    private var logHandle: FileHandle?
    private var isQuitting = false
    private var outputBuffer = ""
    private var statusIconCache: [StatusVisualState: NSImage] = [:]

    private lazy var appSupportDirectory: URL = {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return baseURL.appendingPathComponent("qmk-hid-host", isDirectory: true)
    }()

    private lazy var configURL: URL = {
        appSupportDirectory.appendingPathComponent("qmk-hid-host.json", isDirectory: false)
    }()

    private lazy var logDirectory: URL = {
        let baseURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return baseURL.appendingPathComponent("Logs/qmk-hid-host", isDirectory: true)
    }()

    private lazy var logURL: URL = {
        logDirectory.appendingPathComponent("qmk-hid-host.log", isDirectory: false)
    }()

    private lazy var launchAgentsDirectory: URL = {
        let baseURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return baseURL.appendingPathComponent("LaunchAgents", isDirectory: true)
    }()

    private lazy var launchAgentURL: URL = {
        launchAgentsDirectory.appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
    }()

    private lazy var configEditorWindowController = ConfigEditorWindowController(
        configURL: configURL,
        hostBinaryURL: hostBinaryURL
    ) { [weak self] in
        self?.restartHostService()
    }

    private lazy var baseStatusBarImage: NSImage? = {
        let svgURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/StatusIcon.svg", isDirectory: false)
        if let image = NSImage(contentsOf: svgURL) {
            return image;
        }

        if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "QMK HID Host") {
            return image
        }

        return nil
    }()

    private var hostBinaryURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/qmk-hid-host-bin", isDirectory: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        do {
            try prepareSupportDirectories()
            try ensureInitialConfigIfNeeded()
            try prepareLogFile()
            syncLaunchAtLoginMenuItem()
            try startHost()
        } catch {
            updateState("Failed to start: \(error.localizedDescription)")
            applyStatusBarAppearance(.problem)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isQuitting = true
        stopHost()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusBarAppearance(.problem)
        statusItem.button?.toolTip = "QMK HID Host"

        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Edit Config", action: #selector(openConfigEditor), keyEquivalent: ","))
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(makeMenuItem(title: "Reveal Logs", action: #selector(revealLogs)))
        menu.addItem(makeMenuItem(title: "Restart Host", action: #selector(restartHost)))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Quit QMK HID Host", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func statusBarImage(for state: StatusVisualState) -> NSImage? {
        if let cached = statusIconCache[state] {
            return cached
        }

        guard let baseStatusBarImage else {
            return nil
        }

        let color: NSColor = switch state {
        case .connected:
            .white
        case .problem:
            .systemRed
        }

        let tinted = tintedImage(from: baseStatusBarImage, color: color, size: NSSize(width: 18, height: 18))
        statusIconCache[state] = tinted
        return tinted
    }

    private func tintedImage(from image: NSImage, color: NSColor, size: NSSize) -> NSImage {
        let tinted = NSImage(size: size)
        tinted.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect, from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceIn)

        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    private func applyStatusBarAppearance(_ state: StatusVisualState) {
        guard let button = statusItem?.button else {
            return
        }

        if let image = statusBarImage(for: state) {
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        } else {
            button.image = nil
            button.title = "QMK"
        }
    }

    private func makeMenuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func prepareSupportDirectories() throws {
        try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    private func ensureInitialConfigIfNeeded() throws {
        guard !fileManager.fileExists(atPath: configURL.path) else {
            return
        }

        var config = defaultConfigObject()
        let systemLayouts = availableSystemLayouts()
        if !systemLayouts.isEmpty {
            config["layouts"] = systemLayouts.map(\.code)
        }

        if
            fileManager.isExecutableFile(atPath: hostBinaryURL.path),
            let output = try? runProcess(
                executableURL: hostBinaryURL,
                arguments: ["-p"],
                environment: ["RUST_LOG": "info"]
            )
        {
            let devices = parseDetectedHIDDevices(from: output)
            if let match = matchedCatalogSelection(in: keyboardCatalog, for: devices) {
                let revision = keyboardCatalog[match.vendor].models[match.model].revisions[match.revision]
                config["devices"] = revision.devices.map(\.jsonObject)
                updateState("Prepared config for \(match.device.productName)")
            } else if !systemLayouts.isEmpty {
                updateState("Prepared config with system layouts")
            }
        }

        let formatted = try formattedJSONString(from: config)
        try formatted.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func prepareLogFile() throws {
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        logHandle = handle
    }

    private func startHost() throws {
        guard hostProcess == nil else {
            return
        }

        guard fileManager.isExecutableFile(atPath: hostBinaryURL.path) else {
            updateState("Host binary is missing")
            return
        }

        let process = Process()
        let pipe = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        process.executableURL = hostBinaryURL
        process.arguments = ["-c", configURL.path]
        process.currentDirectoryURL = appSupportDirectory
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hostOutputPipe?.fileHandleForReading.readabilityHandler = nil
                self.hostOutputPipe = nil
                self.hostProcess = nil
                if !self.isQuitting {
                    self.updateState("Stopped (exit \(process.terminationStatus))")
                    self.applyStatusBarAppearance(.problem)
                }
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.logHandle?.write(data)
            self.consumeOutput(data)
        }

        updateState("Starting...")
        applyStatusBarAppearance(.problem)
        try process.run()
        hostProcess = process
        hostOutputPipe = pipe
        updateState("Running")
    }

    private func stopHost() {
        hostOutputPipe?.fileHandleForReading.readabilityHandler = nil
        hostOutputPipe = nil

        guard let process = hostProcess else {
            return
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        hostProcess = nil
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(String(decoding: data, as: UTF8.self))

        while let newlineRange = outputBuffer.range(of: "\n") {
            let line = String(outputBuffer[..<newlineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            outputBuffer.removeSubrange(..<newlineRange.upperBound)
            handleLogLine(line)
        }
    }

    private func handleLogLine(_ line: String) {
        guard !line.isEmpty else {
            return
        }

        if let range = line.range(of: "Connected devices: ") {
            let countString = line[range.upperBound...]
            updateState("Connected devices: \(countString)")
            if Int(countString.trimmingCharacters(in: .whitespaces)) ?? 0 > 0 {
                applyStatusBarAppearance(.connected)
            } else {
                applyStatusBarAppearance(.problem)
            }
        } else if line.contains("Waiting for") {
            updateState("Waiting for keyboard...")
            applyStatusBarAppearance(.problem)
        } else if line.contains(": disconnected") {
            updateState("Keyboard disconnected")
            applyStatusBarAppearance(.problem)
        } else if line.contains("New config file created") {
            updateState("Default config created")
            applyStatusBarAppearance(.problem)
        }
    }

    private func updateState(_ value: String) {
        DispatchQueue.main.async {
            self.stateMenuItem.title = value
        }
    }

    @objc
    private func openConfigEditor() {
        configEditorWindowController.showEditor()
    }

    @objc
    private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            try setLaunchAtLogin(enabled: sender.state != .on)
            syncLaunchAtLoginMenuItem()
        } catch {
            syncLaunchAtLoginMenuItem()
            presentAlert(title: "Launch at Login", message: error.localizedDescription)
        }
    }

    @objc
    private func revealLogs() {
        if fileManager.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            NSWorkspace.shared.open(logDirectory)
        }
    }

    @objc
    private func restartHost() {
        restartHostService()
    }

    private func restartHostService() {
        stopHost()
        outputBuffer.removeAll(keepingCapacity: true)

        do {
            try startHost()
        } catch {
            updateState("Failed to restart: \(error.localizedDescription)")
        }
    }

    @objc
    private func quitApp() {
        isQuitting = true
        NSApp.terminate(nil)
    }

    private func syncLaunchAtLoginMenuItem() {
        launchAtLoginMenuItem.state = fileManager.fileExists(atPath: launchAgentURL.path) ? .on : .off
    }

    private func setLaunchAtLogin(enabled: Bool) throws {
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        if enabled {
            let plist = try launchAgentPropertyList()
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL, options: .atomic)

            try? runLaunchCtl(["bootout", launchDomain, launchAgentURL.path])
            try runLaunchCtl(["bootstrap", launchDomain, launchAgentURL.path])
        } else {
            try? runLaunchCtl(["bootout", launchDomain, launchAgentURL.path])
            if fileManager.fileExists(atPath: launchAgentURL.path) {
                try fileManager.removeItem(at: launchAgentURL)
            }
        }
    }

    private func launchAgentPropertyList() throws -> [String: Any] {
        let appPath = Bundle.main.bundleURL.path
        guard fileManager.fileExists(atPath: appPath) else {
            throw NSError(
                domain: "QMKHIDHost",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "App bundle path does not exist: \(appPath)"]
            )
        }

        return [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", "-g", appPath],
            "RunAtLoad": true,
        ]
    }

    private var launchDomain: String {
        "gui/\(getuid())"
    }

    private func runLaunchCtl(_ arguments: [String]) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let message = output.isEmpty ? "launchctl exited with status \(process.terminationStatus)." : output
            throw NSError(domain: "QMKHIDHost", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

final class ConfigEditorWindowController: NSWindowController {
    private let configURL: URL
    private let hostBinaryURL: URL
    private let onSaveAndRestart: () -> Void
    private let keyboardCatalog: [KeyboardVendor]
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 440))
    private let detectedDevicesView = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 88))
    private let layoutsView = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 110))
    private let statusLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let vendorPopUpButton = NSPopUpButton()
    private let modelPopUpButton = NSPopUpButton()
    private let revisionPopUpButton = NSPopUpButton()
    private let weatherEnabledButton = NSButton(checkboxWithTitle: "Enable Weather", target: nil, action: nil)
    private let reverseLayoutOrderButton = NSButton(checkboxWithTitle: "Reverse order in config", target: nil, action: nil)
    private let weatherCityField = NSTextField()
    private var detectedSystemLayouts: [SystemLayout] = []
    private var isSynchronizingControls = false

    init(configURL: URL, hostBinaryURL: URL, onSaveAndRestart: @escaping () -> Void) {
        self.configURL = configURL
        self.hostBinaryURL = hostBinaryURL
        self.onSaveAndRestart = onSaveAndRestart
        self.keyboardCatalog = loadKeyboardCatalog()

        let window = ConfigEditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)
        setupWindow()
        refreshEditorContext(statusMessage: "Loaded current config.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showEditor() {
        refreshEditorContext(statusMessage: "Loaded current config.")
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupWindow() {
        guard let window else {
            return
        }

        window.title = "Edit Config"
        window.isReleasedWhenClosed = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.stringValue = configURL.path
        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let keyboardLabel = makeSectionLabel("Keyboard Profile")
        let weatherLabel = makeSectionLabel("Weather")
        let layoutsLabel = makeSectionLabel("Detected System Layouts")

        configureTextView(textView, isEditable: true)
        configureTextView(detectedDevicesView, isEditable: false)
        configureTextView(layoutsView, isEditable: false)

        let editorScrollView = makeScrollView(for: textView)
        let detectedDevicesScrollView = makeScrollView(for: detectedDevicesView)
        let layoutsScrollView = makeScrollView(for: layoutsView)

        vendorPopUpButton.target = self
        vendorPopUpButton.action = #selector(vendorSelectionChanged)
        modelPopUpButton.target = self
        modelPopUpButton.action = #selector(modelSelectionChanged)
        revisionPopUpButton.target = self
        revisionPopUpButton.action = #selector(revisionSelectionChanged)
        weatherEnabledButton.target = self
        weatherEnabledButton.action = #selector(weatherToggleChanged)
        reverseLayoutOrderButton.target = self
        reverseLayoutOrderButton.action = #selector(reverseLayoutOrderChanged)
        weatherCityField.target = self
        weatherCityField.action = #selector(applyWeatherFromControls)
        weatherCityField.placeholderString = "City for wttr.in, for example Orenburg"

        rebuildVendorPopup()

        let keyboardControls = NSStackView(views: [
            makeCaptionLabel("Vendor"),
            vendorPopUpButton,
            makeCaptionLabel("Model"),
            modelPopUpButton,
            makeCaptionLabel("Version"),
            revisionPopUpButton,
        ])
        keyboardControls.translatesAutoresizingMaskIntoConstraints = false
        keyboardControls.orientation = .horizontal
        keyboardControls.spacing = 10
        keyboardControls.alignment = .centerY

        let detectKeyboardsButton = makeButton(title: "Detect Keyboards", action: #selector(detectKeyboards))
        let keyboardHeader = makeHeaderRow(label: keyboardLabel, trailingViews: [detectKeyboardsButton])

        let applyWeatherButton = makeButton(title: "Apply Weather", action: #selector(applyWeatherFromControls))
        let testWeatherButton = makeButton(title: "Test Weather", action: #selector(testWeather))
        let weatherControls = NSStackView(views: [
            weatherEnabledButton,
            makeCaptionLabel("City"),
            weatherCityField,
            applyWeatherButton,
            testWeatherButton,
        ])
        weatherControls.translatesAutoresizingMaskIntoConstraints = false
        weatherControls.orientation = .horizontal
        weatherControls.spacing = 10
        weatherControls.alignment = .centerY

        let refreshLayoutsButton = makeButton(title: "Refresh Languages", action: #selector(refreshLanguages))
        let layoutsHeader = makeHeaderRow(label: layoutsLabel, trailingViews: [reverseLayoutOrderButton, refreshLayoutsButton])

        let helperStack = NSStackView(views: [
            keyboardHeader,
            keyboardControls,
            detectedDevicesScrollView,
            weatherLabel,
            weatherControls,
            layoutsHeader,
            layoutsScrollView,
        ])
        helperStack.translatesAutoresizingMaskIntoConstraints = false
        helperStack.orientation = .vertical
        helperStack.spacing = 10

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Choose a keyboard profile and save the JSON config."
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let reloadButton = makeButton(title: "Reload", action: #selector(reloadConfig))
        let saveButton = makeButton(title: "Save", action: #selector(saveConfig))
        let saveAndRestartButton = makeButton(title: "Save & Restart", action: #selector(saveAndRestart))

        let buttonStack = NSStackView(views: [reloadButton, saveButton, saveAndRestartButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.alignment = .centerY

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footerStack = NSStackView(views: [statusLabel, spacer, buttonStack])
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.orientation = .horizontal
        footerStack.spacing = 12
        footerStack.alignment = .centerY

        contentView.addSubview(pathLabel)
        contentView.addSubview(helperStack)
        contentView.addSubview(editorScrollView)
        contentView.addSubview(footerStack)

        NSLayoutConstraint.activate([
            pathLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            pathLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            pathLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            helperStack.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 12),
            helperStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            helperStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            detectedDevicesScrollView.heightAnchor.constraint(equalToConstant: 90),
            layoutsScrollView.heightAnchor.constraint(equalToConstant: 120),

            editorScrollView.topAnchor.constraint(equalTo: helperStack.bottomAnchor, constant: 12),
            editorScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            editorScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            editorScrollView.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -12),

            footerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            footerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            footerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func refreshEditorContext(statusMessage: String) {
        loadConfigFromDisk(statusMessage: statusMessage)
        syncKeyboardSelectionFromConfig()
        syncWeatherControlsFromConfig()
        refreshSystemLayouts(applyToConfig: false)
        syncLayoutControlsFromConfig()
        updateDetectedDevicesView(with: [], statusMessage: nil)

        if !configHasLayouts() && !detectedSystemLayouts.isEmpty {
            applyDetectedLayoutsToConfig(statusMessage: "Applied detected system languages to config.", showAlertOnFailure: false)
        }

        if !configHasDevices() && selectedRevision != nil {
            applySelectedKeyboardToConfig(statusMessage: "Applied selected keyboard profile to config.")
        }
    }

    private func configureTextView(_ textView: NSTextView, isEditable: Bool) {
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = true
        textView.allowsUndo = isEditable
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: textView.frame.width - (textView.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
    }

    private func makeScrollView(for textView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView
        let contentSize = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.textContainer?.containerSize = NSSize(
            width: max(0, contentSize.width - (textView.textContainerInset.width * 2)),
            height: CGFloat.greatestFiniteMagnitude
        )
        return scrollView
    }

    private func resetTextViewport(for textView: NSTextView) {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        if let scrollView = textView.enclosingScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func makeHeaderRow(label: NSView, trailingViews: [NSView]) -> NSStackView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let views = [label, spacer] + trailingViews
        let stack = NSStackView(views: views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func makeCaptionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func rebuildVendorPopup() {
        isSynchronizingControls = true
        vendorPopUpButton.removeAllItems()
        if keyboardCatalog.isEmpty {
            vendorPopUpButton.addItem(withTitle: "No catalog")
            vendorPopUpButton.isEnabled = false
            rebuildModelPopup()
            isSynchronizingControls = false
            return
        }

        vendorPopUpButton.isEnabled = true
        vendorPopUpButton.addItems(withTitles: keyboardCatalog.map(\.name))
        vendorPopUpButton.selectItem(at: 0)
        rebuildModelPopup()
        isSynchronizingControls = false
    }

    private func rebuildModelPopup() {
        modelPopUpButton.removeAllItems()
        let titles = selectedVendor?.models.map(\.name) ?? []
        if titles.isEmpty {
            modelPopUpButton.addItem(withTitle: "No models")
            modelPopUpButton.isEnabled = false
            rebuildRevisionPopup()
            return
        }

        modelPopUpButton.isEnabled = true
        modelPopUpButton.addItems(withTitles: titles)
        modelPopUpButton.selectItem(at: 0)
        rebuildRevisionPopup()
    }

    private func rebuildRevisionPopup() {
        revisionPopUpButton.removeAllItems()
        let titles = selectedModel?.revisions.map(\.name) ?? []
        if titles.isEmpty {
            revisionPopUpButton.addItem(withTitle: "No revisions")
            revisionPopUpButton.isEnabled = false
            return
        }

        revisionPopUpButton.isEnabled = true
        revisionPopUpButton.addItems(withTitles: titles)
        revisionPopUpButton.selectItem(at: 0)
    }

    private var selectedVendor: KeyboardVendor? {
        guard vendorPopUpButton.indexOfSelectedItem >= 0, vendorPopUpButton.indexOfSelectedItem < keyboardCatalog.count else {
            return keyboardCatalog.first
        }
        return keyboardCatalog[vendorPopUpButton.indexOfSelectedItem]
    }

    private var selectedModel: KeyboardModel? {
        guard let selectedVendor else {
            return nil
        }
        let index = modelPopUpButton.indexOfSelectedItem
        guard index >= 0, index < selectedVendor.models.count else {
            return selectedVendor.models.first
        }
        return selectedVendor.models[index]
    }

    private var selectedRevision: KeyboardRevision? {
        guard let selectedModel else {
            return nil
        }
        let index = revisionPopUpButton.indexOfSelectedItem
        guard index >= 0, index < selectedModel.revisions.count else {
            return selectedModel.revisions.first
        }
        return selectedModel.revisions[index]
    }

    private func syncKeyboardSelectionFromConfig() {
        guard
            let config = try? parseConfigObject(),
            let devices = config["devices"] as? [Any],
            let match = matchingRevisionIndex(for: devices)
        else {
            return
        }

        isSynchronizingControls = true
        vendorPopUpButton.selectItem(at: match.vendor)
        rebuildModelPopup()
        modelPopUpButton.selectItem(at: match.model)
        rebuildRevisionPopup()
        revisionPopUpButton.selectItem(at: match.revision)
        isSynchronizingControls = false
    }

    private func matchingRevisionIndex(for devices: [Any]) -> (vendor: Int, model: Int, revision: Int)? {
        guard let devicesSignature = canonicalJSONSignature(for: devices) else {
            return nil
        }

        for (vendorIndex, vendor) in keyboardCatalog.enumerated() {
            for (modelIndex, model) in vendor.models.enumerated() {
                for (revisionIndex, revision) in model.revisions.enumerated() {
                    if let signature = canonicalJSONSignature(for: revision.devices.map(\.jsonObject)), signature == devicesSignature {
                        return (vendorIndex, modelIndex, revisionIndex)
                    }
                }
            }
        }

        return nil
    }

    private func loadConfigFromDisk(statusMessage: String) {
        do {
            let contents = try String(contentsOf: configURL, encoding: .utf8)
            textView.string = contents
            resetTextViewport(for: textView)
            setStatus(statusMessage)
        } catch {
            textView.string = ""
            resetTextViewport(for: textView)
            setStatus("Failed to load config: \(error.localizedDescription)", isError: true)
        }
    }

    private func syncWeatherControlsFromConfig() {
        guard let config = try? parseConfigObject() else {
            return
        }

        if
            let weather = config["weather"] as? [String: Any],
            let url = weather["url"] as? String
        {
            weatherEnabledButton.state = .on
            weatherCityField.stringValue = weatherCity(from: url) ?? ""
        } else {
            weatherEnabledButton.state = .off
            weatherCityField.stringValue = ""
        }
    }

    private func configHasDevices() -> Bool {
        guard let config = try? parseConfigObject(), let devices = config["devices"] as? [Any] else {
            return false
        }

        return !devices.isEmpty
    }

    private func configHasLayouts() -> Bool {
        guard let config = try? parseConfigObject(), let layouts = config["layouts"] as? [String] else {
            return false
        }

        return !layouts.isEmpty
    }

    private func parseConfigObject() throws -> [String: Any] {
        guard let data = textView.string.data(using: .utf8) else {
            throw NSError(domain: "QMKHIDHost", code: 10, userInfo: [NSLocalizedDescriptionKey: "Config contains invalid UTF-8 data."])
        }

        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw NSError(domain: "QMKHIDHost", code: 11, userInfo: [NSLocalizedDescriptionKey: "Top level config must be a JSON object."])
        }

        return dictionary
    }

    private func writeConfigObject(_ object: [String: Any], statusMessage: String, showAlertOnFailure: Bool = true) {
        do {
            let formatted = try formattedJSONString(from: object)
            textView.string = formatted
            resetTextViewport(for: textView)
            setStatus(statusMessage)
        } catch {
            if showAlertOnFailure {
                presentError(title: "Unable to Update Config", message: error.localizedDescription)
            }
            setStatus("Unable to update config from helpers.", isError: true)
        }
    }

    private func canonicalJSONSignature(for value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func applySelectedKeyboardToConfig(statusMessage: String) {
        guard let selectedRevision else {
            return
        }

        do {
            var config = try parseConfigObject()
            config["devices"] = selectedRevision.devices.map(\.jsonObject)
            writeConfigObject(config, statusMessage: statusMessage)
        } catch {
            setStatus("Fix JSON to use keyboard helper.", isError: true)
        }
    }

    private func applyDetectedDeviceToConfig(_ detectedDevice: DetectedHIDDevice, statusMessage: String) {
        do {
            var config = try parseConfigObject()
            config["devices"] = [detectedDevice.fallbackConfigObject]
            writeConfigObject(config, statusMessage: statusMessage)
        } catch {
            setStatus("Fix JSON to use keyboard detection.", isError: true)
        }
    }

    private func detectedLayoutCodesForConfig() -> [String] {
        let codes = detectedSystemLayouts.map(\.code)
        if reverseLayoutOrderButton.state == .on {
            return Array(codes.reversed())
        }

        return codes
    }

    private func syncLayoutControlsFromConfig() {
        let systemCodes = detectedSystemLayouts.map(\.code)
        guard
            !systemCodes.isEmpty,
            let config = try? parseConfigObject(),
            let layouts = config["layouts"] as? [String]
        else {
            reverseLayoutOrderButton.state = .off
            return
        }

        reverseLayoutOrderButton.state = layouts == Array(systemCodes.reversed()) ? .on : .off
    }

    private func applyDetectedLayoutsToConfig(statusMessage: String, showAlertOnFailure: Bool = true) {
        do {
            var config = try parseConfigObject()
            config["layouts"] = detectedLayoutCodesForConfig()
            writeConfigObject(config, statusMessage: statusMessage, showAlertOnFailure: showAlertOnFailure)
        } catch {
            setStatus("Fix JSON to use language helper.", isError: true)
        }
    }

    private func refreshSystemLayouts(applyToConfig: Bool) {
        detectedSystemLayouts = availableSystemLayouts()
        if detectedSystemLayouts.isEmpty {
            layoutsView.string = "No selectable keyboard layouts were detected."
            setStatus("No system layouts detected.", isError: true)
            return
        }

        layoutsView.string = detectedSystemLayouts
            .enumerated()
            .map { "\($0.offset + 1). \($0.element.code) -> \($0.element.localizedName)" }
            .joined(separator: "\n")
        resetTextViewport(for: layoutsView)

        guard applyToConfig else {
            return
        }

        applyDetectedLayoutsToConfig(
            statusMessage: reverseLayoutOrderButton.state == .on
                ? "Updated layouts from system input sources in reverse order."
                : "Updated layouts from system input sources.",
            showAlertOnFailure: false
        )
    }

    private func saveCurrentConfig(restartHost: Bool) {
        do {
            let jsonObject = try parseConfigObject()
            let formattedText = try formattedJSONString(from: jsonObject)
            try formattedText.write(to: configURL, atomically: true, encoding: .utf8)
            textView.string = formattedText

            if restartHost {
                setStatus("Saved config. Restarting host...")
                onSaveAndRestart()
                setStatus("Saved config and restarted host.")
            } else {
                setStatus("Saved config.")
            }
        } catch {
            presentError(title: "Invalid Config", message: error.localizedDescription)
            setStatus("Config is invalid JSON.", isError: true)
        }
    }

    private func setStatus(_ message: String, isError: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func weatherCity(from url: String) -> String? {
        guard let range = url.range(of: "wttr.in/") else {
            return nil
        }

        let suffix = url[range.upperBound...]
        let encodedCity = suffix.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard !encodedCity.isEmpty else {
            return nil
        }

        return encodedCity.removingPercentEncoding ?? encodedCity
    }

    private func weatherURL(for city: String) -> String {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        return "wttr.in/\(encoded)?format=%t"
    }

    private func weatherTestURL(for city: String) -> String {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        return "https://wttr.in/\(encoded)?format=%t"
    }

    private func updateDetectedDevicesView(with devices: [DetectedHIDDevice], statusMessage: String?) {
        if devices.isEmpty {
            detectedDevicesView.string = "Press Detect Keyboards to inspect connected HID devices."
        } else {
            detectedDevicesView.string = devices.map { device in
                let usagePageString = device.usagePage.map(String.init) ?? "-"
                let usageString = device.usage.map(String.init) ?? "-"
                return "\(device.productName) -> VID \(device.vendorId), PID \(device.productId), usagePage \(usagePageString), usage \(usageString)"
            }.joined(separator: "\n")
        }

        detectedDevicesView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        resetTextViewport(for: detectedDevicesView)
        if let statusMessage {
            setStatus(statusMessage)
        }
    }

    private func matchedRevision(for devices: [DetectedHIDDevice]) -> (vendor: Int, model: Int, revision: Int, device: DetectedHIDDevice)? {
        matchedCatalogSelection(in: keyboardCatalog, for: devices)
    }

    private func fallbackDetectedDevice(from devices: [DetectedHIDDevice]) -> DetectedHIDDevice? {
        if let nonApple = devices.first(where: { normalizeHex($0.vendorId) != "004c" }) {
            return nonApple
        }

        return devices.first
    }

    @objc
    private func vendorSelectionChanged() {
        guard !isSynchronizingControls else {
            return
        }

        isSynchronizingControls = true
        rebuildModelPopup()
        isSynchronizingControls = false
        applySelectedKeyboardToConfig(statusMessage: "Applied selected keyboard profile to config.")
    }

    @objc
    private func modelSelectionChanged() {
        guard !isSynchronizingControls else {
            return
        }

        isSynchronizingControls = true
        rebuildRevisionPopup()
        isSynchronizingControls = false
        applySelectedKeyboardToConfig(statusMessage: "Applied selected keyboard profile to config.")
    }

    @objc
    private func revisionSelectionChanged() {
        guard !isSynchronizingControls else {
            return
        }

        applySelectedKeyboardToConfig(statusMessage: "Applied selected keyboard profile to config.")
    }

    @objc
    private func refreshLanguages() {
        refreshSystemLayouts(applyToConfig: true)
    }

    @objc
    private func reverseLayoutOrderChanged() {
        guard !detectedSystemLayouts.isEmpty else {
            return
        }

        applyDetectedLayoutsToConfig(
            statusMessage: reverseLayoutOrderButton.state == .on
                ? "Updated layouts using reverse system order."
                : "Updated layouts using system order."
        )
    }

    @objc
    private func detectKeyboards() {
        do {
            let output = try runProcess(
                executableURL: hostBinaryURL,
                arguments: ["-p"],
                environment: ["RUST_LOG": "info"]
            )
            let devices = parseDetectedHIDDevices(from: output)
            updateDetectedDevicesView(with: devices, statusMessage: devices.isEmpty ? "No HID devices detected." : "Detected \(devices.count) HID device(s).")

            if let match = matchedRevision(for: devices) {
                isSynchronizingControls = true
                vendorPopUpButton.selectItem(at: match.vendor)
                rebuildModelPopup()
                modelPopUpButton.selectItem(at: match.model)
                rebuildRevisionPopup()
                revisionPopUpButton.selectItem(at: match.revision)
                isSynchronizingControls = false
                applySelectedKeyboardToConfig(statusMessage: "Detected \(match.device.productName) and applied matching profile.")
                refreshSystemLayouts(applyToConfig: true)
                return
            }

            if let fallback = fallbackDetectedDevice(from: devices) {
                applyDetectedDeviceToConfig(fallback, statusMessage: "Detected \(fallback.productName) and wrote fallback device settings.")
                refreshSystemLayouts(applyToConfig: true)
                return
            }

            setStatus("No suitable keyboard device detected.", isError: true)
        } catch {
            presentError(title: "Detect Keyboards", message: error.localizedDescription)
            setStatus("Keyboard detection failed.", isError: true)
        }
    }

    @objc
    private func weatherToggleChanged() {
        if weatherEnabledButton.state == .off {
            applyWeatherFromControls()
        } else {
            setStatus("Weather enabled. Enter a city and press Apply Weather.")
        }
    }

    @objc
    private func applyWeatherFromControls() {
        do {
            var config = try parseConfigObject()
            if weatherEnabledButton.state == .off {
                config.removeValue(forKey: "weather")
                writeConfigObject(config, statusMessage: "Disabled weather provider.")
                return
            }

            let city = weatherCityField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !city.isEmpty else {
                setStatus("Enter a city to enable weather.", isError: true)
                return
            }

            config["weather"] = ["url": weatherURL(for: city)]
            writeConfigObject(config, statusMessage: "Updated weather city to \(city).")
        } catch {
            setStatus("Fix JSON to use weather helper.", isError: true)
        }
    }

    @objc
    private func testWeather() {
        guard weatherEnabledButton.state == .on else {
            setStatus("Weather is disabled.")
            return
        }

        let city = weatherCityField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else {
            setStatus("Enter a city before testing weather.", isError: true)
            return
        }

        do {
            let output = try runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: ["-fsSL", "--max-time", "10", weatherTestURL(for: city)]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else {
                throw NSError(domain: "QMKHIDHost", code: 30, userInfo: [NSLocalizedDescriptionKey: "wttr.in returned an empty response."])
            }
            setStatus("Weather OK for \(city): \(output)")
        } catch {
            presentError(title: "Test Weather", message: error.localizedDescription)
            setStatus("Weather lookup failed.", isError: true)
        }
    }

    @objc
    private func reloadConfig() {
        refreshEditorContext(statusMessage: "Reloaded config from disk.")
    }

    @objc
    private func saveConfig() {
        saveCurrentConfig(restartHost: false)
    }

    @objc
    private func saveAndRestart() {
        saveCurrentConfig(restartHost: true)
    }
}
