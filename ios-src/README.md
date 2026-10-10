# iOS App Source

SwiftUI client for the KV4P-HT over BLE. Open `KV4P HT/KV4P HT.xcodeproj` in
Xcode (deployment target iOS 18.0; live captions need iOS 26).

Architecture, protocol details, the background-audio and mic-indicator designs,
and the on-device verification checklist live in
[docs/ios-app.md](../docs/ios-app.md).

Note: this app targets the firmware from
[dkaukov/kv4p-ht `feature/ble`](https://github.com/dkaukov/kv4p-ht/tree/feature/ble),
not this repo's `microcontroller-src/`.

## Dependencies

The only native dependency is [`Codec2/`](Codec2), a local Swift package for
FreeDV 2400B digital voice. It is a vendored Codec2 1.2.0 subset (LGPL-2.1) that
Xcode builds automatically. Run `swift test` in `ios-src/Codec2` to test it alone.
See [Codec2/README.md](Codec2/README.md) for how to refresh the sources.

## TestFlight builds

```sh
ios-src/scripts/testflight.sh                 # archive + upload to App Store Connect
ios-src/scripts/testflight.sh --archive-only  # archive + verify, no upload
```

The script archives the `KV4P HT` scheme (Release) with
`CURRENT_PROJECT_VERSION` set to a UTC timestamp (`YYYYMMDDHHMM`), so every
upload gets a unique, increasing build number without editing the project. The
command-line override applies to every target, keeping the app and the
APRSMonitorWidget extension in lockstep; the script checks both
`CFBundleVersion`s in the archive before uploading. Export/upload settings live
in [`scripts/ExportOptions.plist`](scripts/ExportOptions.plist). Set
`BUILD_NUMBER=...` to override the timestamp. Archives land in
`ios-src/build/testflight/<build>/` (git-ignored). Bump `MARKETING_VERSION` in
the project for a new user-facing version.
