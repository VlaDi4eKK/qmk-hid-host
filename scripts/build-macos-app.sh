#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="QMK HID Host"
APP_BUNDLE_PATH="$ROOT_DIR/dist/$APP_NAME.app"
APP_CONTENTS_PATH="$APP_BUNDLE_PATH/Contents"
APP_MACOS_PATH="$APP_CONTENTS_PATH/MacOS"
APP_RESOURCES_PATH="$APP_CONTENTS_PATH/Resources"
RUST_BINARY_PATH="$ROOT_DIR/target/release/qmk-hid-host"
SWIFT_MODULE_CACHE_PATH="$ROOT_DIR/target/swift-module-cache"
ICON_SOURCE_PATH="$ROOT_DIR/macos/MenuBarApp/AppIcon.icns"
ICON_OUTPUT_PATH="$APP_RESOURCES_PATH/AppIcon.icns"
STATUS_ICON_SOURCE_PATH="$ROOT_DIR/macos/MenuBarApp/StatusIcon.svg"
STATUS_ICON_OUTPUT_PATH="$APP_RESOURCES_PATH/StatusIcon.svg"
KEYBOARD_CATALOG_SOURCE_PATH="$ROOT_DIR/macos/MenuBarApp/KeyboardCatalog.json"
KEYBOARD_CATALOG_OUTPUT_PATH="$APP_RESOURCES_PATH/KeyboardCatalog.json"
WRAPPER_BINARY_PATH="$APP_MACOS_PATH/qmk-hid-host"
HOST_BINARY_PATH="$APP_MACOS_PATH/qmk-hid-host-bin"
SWIFT_SOURCE_PATH="$ROOT_DIR/macos/MenuBarApp/main.swift"
INFO_PLIST_PATH="$ROOT_DIR/macos/MenuBarApp/Info.plist"

cargo build --release --manifest-path "$ROOT_DIR/Cargo.toml"

rm -rf "$APP_BUNDLE_PATH"
mkdir -p "$APP_MACOS_PATH"
mkdir -p "$APP_RESOURCES_PATH"
mkdir -p "$SWIFT_MODULE_CACHE_PATH"
cp "$ICON_SOURCE_PATH" "$ICON_OUTPUT_PATH"
cp "$STATUS_ICON_SOURCE_PATH" "$STATUS_ICON_OUTPUT_PATH"
cp "$KEYBOARD_CATALOG_SOURCE_PATH" "$KEYBOARD_CATALOG_OUTPUT_PATH"

cp "$RUST_BINARY_PATH" "$HOST_BINARY_PATH"
chmod +x "$HOST_BINARY_PATH"

xcrun swiftc \
    -module-cache-path "$SWIFT_MODULE_CACHE_PATH" \
    -parse-as-library \
    "$SWIFT_SOURCE_PATH" \
    -o "$WRAPPER_BINARY_PATH"

chmod +x "$WRAPPER_BINARY_PATH"
cp "$INFO_PLIST_PATH" "$APP_CONTENTS_PATH/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_BUNDLE_PATH" >/dev/null
fi

echo "Built app bundle at $APP_BUNDLE_PATH"
