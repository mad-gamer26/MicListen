# MicListen iOS

SwiftUI client for MicListen streamers and relays.

## Features

- Save and manage multiple MicListen endpoints.
- Automatically detects direct streamer servers and relay servers.
- Expands relay servers into their connected streamer paths.
- Stores passwords in Keychain and endpoint metadata in UserDefaults.
- Plays MicListen's native live MP3 stream with background audio enabled.
- Supports local HTTP/LAN endpoints and HTTPS relay deployments.

## Build

Open `MicListen.xcodeproj` in Xcode, choose a simulator or device, and run the
`MicListen` target. Set a development team in the target signing settings before
installing on a physical device.
