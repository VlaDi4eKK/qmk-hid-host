# Graph Report - .  (2026-06-27)

## Corpus Check
- Corpus is ~22,098 words - fits in a single context window. You may not need a graph.

## Summary
- 277 nodes · 475 edges · 25 communities (21 shown, 4 thin omitted)
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 28 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_macOS Config Editor UI|macOS Config Editor UI]]
- [[_COMMUNITY_HID Protocol & Data Types|HID Protocol & Data Types]]
- [[_COMMUNITY_Swift Config Models|Swift Config Models]]
- [[_COMMUNITY_macOS Menu-Bar App|macOS Menu-Bar App]]
- [[_COMMUNITY_Layout Provider|Layout Provider]]
- [[_COMMUNITY_Config Loading & Entry Point|Config Loading & Entry Point]]
- [[_COMMUNITY_Linux Media Provider|Linux Media Provider]]
- [[_COMMUNITY_macOS Volume Provider|macOS Volume Provider]]
- [[_COMMUNITY_Windows Volume Provider|Windows Volume Provider]]
- [[_COMMUNITY_Windows Media Provider|Windows Media Provider]]
- [[_COMMUNITY_macOS Media Provider|macOS Media Provider]]
- [[_COMMUNITY_Time Provider|Time Provider]]
- [[_COMMUNITY_Weather Provider|Weather Provider]]
- [[_COMMUNITY_Keyboard HID Connection|Keyboard HID Connection]]
- [[_COMMUNITY_Linux Volume Provider|Linux Volume Provider]]
- [[_COMMUNITY_Relay Provider|Relay Provider]]
- [[_COMMUNITY_Provider Trait|Provider Trait]]
- [[_COMMUNITY_DataType Enum|DataType Enum]]
- [[_COMMUNITY_Windows Platform|Windows Platform]]

## God Nodes (most connected - your core abstractions)
1. `ConfigEditorWindowController` - 52 edges
2. `AppDelegate` - 29 edges
3. `Config` - 11 edges
4. `QMK HID Host` - 10 edges
5. `hid_data_type Enum` - 9 edges
6. `availableSystemLayouts()` - 7 edges
7. `Media Info Provider` - 6 edges
8. `parseDetectedHIDDevices()` - 5 edges
9. `get_config()` - 5 edges
10. `handle_session()` - 5 edges

## Surprising Connections (you probably didn't know these)
- `Menu Bar Status Icon` --conceptually_related_to--> `macOS Menu Bar App`  [INFERRED]
  macos/MenuBarApp/StatusIcon.svg → README.md
- `App Icon (Keycap XE)` --conceptually_related_to--> `macOS Menu Bar App`  [INFERRED]
  macos/MenuBarApp/AppIcon.jpg → README.md
- `App Icon (Keycap XE)` --conceptually_related_to--> `Input Layout Provider`  [INFERRED]
  macos/MenuBarApp/AppIcon.jpg → README.md
- `get_providers()` --calls--> `get_config()`  [INFERRED]
  src/main.rs → src/config.rs
- `main()` --calls--> `load_config()`  [INFERRED]
  src/main.rs → src/config.rs

## Hyperedges (group relationships)
- **Providers sending data to keyboard via Raw HID** — readme_time_provider, readme_volume_provider, readme_layout_provider, readme_media_provider, readme_weather_provider, readme_qmk_hid_host, readme_raw_hid [INFERRED 0.85]
- **Linux provider backing technologies** — readme_linux, readme_pulseaudio, readme_x11, readme_mpris_dbus, readme_wttr_in [EXTRACTED 1.00]

## Communities (25 total, 4 thin omitted)

### Community 0 - "macOS Config Editor UI"
Cohesion: 0.1
Nodes (5): ConfigEditorWindowController, formattedJSONString(), runProcess(), NSWindowController, Config

### Community 1 - "HID Protocol & Data Types"
Cohesion: 0.09
Nodes (32): App Icon (Keycap XE), Menu Bar Status Icon, qmk-hid-host.json Config File, _LAYOUT, _MEDIA_ARTIST, _MEDIA_PLAYER_LINUX (0xB0), _MEDIA_TITLE, _RELAY_FROM_DEVICE (0xCC) (+24 more)

### Community 2 - "Swift Config Models"
Cohesion: 0.1
Nodes (25): Decodable, Hashable, availableSystemLayouts(), boolProperty(), ConfigEditorWindow, defaultConfigObject(), DetectedHIDDevice, KeyboardCatalogFile (+17 more)

### Community 3 - "macOS Menu-Bar App"
Cohesion: 0.14
Nodes (3): AppDelegate, NSApplicationDelegate, NSObject

### Community 4 - "Layout Provider"
Cohesion: 0.11
Nodes (11): get_layout_index(), get_symbols(), LayoutProvider, send_data(), get_keyboard_layout(), LayoutProvider, send_data(), get_layout() (+3 more)

### Community 5 - "Config Loading & Entry Point"
Cohesion: 0.17
Nodes (10): default_layouts(), Device, load_config(), WeatherConfig, Args, get_providers(), main(), run() (+2 more)

### Community 6 - "Linux Media Provider"
Cohesion: 0.33
Nodes (7): compact_media_text(), get_display_title(), MediaProvider, send_data(), send_media_data(), send_media_player_text(), truncate_utf8_bytes()

### Community 7 - "macOS Volume Provider"
Cohesion: 0.33
Nodes (7): get_channel(), get_current_volume(), is_volume_control_supported(), register_device_change_listener(), register_volume_listener(), send_data(), VolumeProvider

### Community 8 - "Windows Volume Provider"
Cohesion: 0.29
Nodes (6): get_volume(), get_volume_endpoint(), send_data(), subscribe_and_wait(), VolumeChangeCallback, VolumeProvider

### Community 9 - "Windows Media Provider"
Cohesion: 0.39
Nodes (5): get_manager(), get_media_data(), handle_session(), MediaProvider, send_data()

### Community 10 - "macOS Media Provider"
Cohesion: 0.43
Nodes (3): get_media_string(), MediaProvider, send_data()

### Community 11 - "Time Provider"
Cohesion: 0.38
Nodes (3): get_time(), send_data(), TimeProvider

### Community 12 - "Weather Provider"
Cohesion: 0.43
Nodes (3): get_weather(), send_data(), WeatherProvider

### Community 13 - "Keyboard HID Connection"
Cohesion: 0.48
Nodes (3): Keyboard, start_read(), start_write()

### Community 14 - "Linux Volume Provider"
Cohesion: 0.43
Nodes (3): get_volume(), send_data(), VolumeProvider

## Knowledge Gaps
- **13 isolated node(s):** `connected`, `problem`, `DataType`, `WeatherConfig`, `Device` (+8 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ConfigEditorWindowController` connect `macOS Config Editor UI` to `Swift Config Models`?**
  _High betweenness centrality (0.122) - this node is a cross-community bridge._
- **Why does `Config` connect `macOS Config Editor UI` to `macOS Menu-Bar App`, `Config Loading & Entry Point`?**
  _High betweenness centrality (0.118) - this node is a cross-community bridge._
- **Why does `get_config()` connect `Layout Provider` to `Config Loading & Entry Point`?**
  _High betweenness centrality (0.088) - this node is a cross-community bridge._
- **Are the 10 inferred relationships involving `Config` (e.g. with `.ensureInitialConfigIfNeeded()` and `.syncKeyboardSelectionFromConfig()`) actually correct?**
  _`Config` has 10 INFERRED edges - model-reasoned connections that need verification._
- **What connects `connected`, `problem`, `DataType` to the rest of the system?**
  _13 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `macOS Config Editor UI` be split into smaller, more focused modules?**
  _Cohesion score 0.1 - nodes in this community are weakly interconnected._
- **Should `HID Protocol & Data Types` be split into smaller, more focused modules?**
  _Cohesion score 0.09 - nodes in this community are weakly interconnected._