# SnapMon

<img src="snapmon.png" alt="SnapMon app icon" width="256">

Monitor your Snapmaker U1.

SnapMon is native macOS SwiftUI application for monitoring a Snapmaker U1 in LAN mode.

It discovers printers over Bonjour, displays the U1 camera feed, tracks print progress and ETA, controls the cavity LED, pauses or resumes a print, and sends a local notification when an observed print finishes.

_SnapMon is not affiliated with, endorsed by, or an official product of Snapmaker._

## Requirements

- macOS 14 or later
- A Snapmaker U1 with LAN mode enabled
- The Mac and printer on the same local network
- Xcode 26 or later, used to compile the Icon Composer app icon

## Run

Because I am not a verified developer with Apple's developer program, I cannot distribute properly signed binaries.

Therefore, you have to build the app yourself. 
Assuming you have Apple's XCode installed it is pretty straight-forward:

```sh
./scripts/build-app.sh
open "build/SnapMon.app"
```

The script compiles `Resources/snapmon.icon` and creates an ad-hoc signed application in `build/`.

## Run during development

Open `Package.swift` in Xcode and run the `SnapMon` executable.

## Tests

```sh
./scripts/test.sh
```

## Network behavior

The app browses `_snapmaker._tcp`, accepts only `Snapmaker U1` devices in `lan` mode, and talks directly to `Moonraker` over the local network.

No Snapmaker cloud account or WAN connection is used.

## Disclaimer

I am no Swift developer.

Therefore, this app has been developed using AI.