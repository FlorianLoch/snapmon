# Snapmaker Monitor

Snapmaker Monitor is a native macOS SwiftUI application for monitoring one Snapmaker U1 in LAN mode.

It discovers printers over Bonjour, displays the U1 camera feed, tracks print progress and ETA, controls the cavity LED, pauses or resumes a print, and sends a local notification when an observed print finishes.

## Requirements

- macOS 14 or later
- A Snapmaker U1 with LAN mode enabled
- The Mac and printer on the same local network
- Xcode 15 or later, or the matching Apple command-line tools

## Run during development

Open `Package.swift` in Xcode and run the `SnapmakerMonitor` executable.

For local-network privacy declarations and notification delivery, use the bundled application produced by the build script:

```sh
./scripts/build-app.sh
open "build/Snapmaker Monitor.app"
```

The script creates an ad-hoc signed application in `build/`.

For distribution, replace the bundle identifier and sign the application with your Developer ID.

## Tests

```sh
./scripts/test.sh
```

## Network behavior

The app browses `_snapmaker._tcp`, accepts only `Snapmaker U1` devices in `lan` mode, and talks directly to Moonraker over the local network.

No Snapmaker cloud account or WAN connection is used.

The camera setting `max_frame_rate` is persisted in `UserDefaults`, accepts values from 1 through 10 FPS, and defaults to 5 FPS.
