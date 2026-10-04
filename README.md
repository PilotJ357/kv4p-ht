# Disclosure 
This is a personal fork to work on adding an iOS app that can connect, via Bluetooth, to a KV4P HT. This is an active work in progress, and currently doesn't follow the design styles required to be an official KV4P app. This attempt is entirely developed leveraging AI, I am not an iOS developer and I tend to take the approach of "Make it functional, then make it pretty". Since there's been interest both in GitHub discussions and Discord, I'm sharing this *well* before it's actually ready or cleaned up. I'm happy to take constructive criticism, but please be aware I entirely accept that this may never leave "Fun side project" status.

# kv4p-ht

Open source handheld ham radio project kv4p HT

Please see the main project site: https://kv4p.com

## Building from source

The site above is for installing a public release. Compiling this repo yourself means building **both** the ESP32 firmware and the Android app from the same git revision.

The firmware resource bundled in the Android app is from the last public release and is not updated until the next one. In a source build there is also no firmware compatibility check, so the app and radio will still connect even if they are out of sync. Flash the firmware and build the Android app from the same commit.

### Clone

```bash
git clone https://github.com/VanceVagell/kv4p-ht.git
cd kv4p-ht
```

### Firmware (ESP32)

See [microcontroller-src/README.md](microcontroller-src/README.md). PlatformIO is the preferred environment; Arduino IDE is documented there too.

Open `microcontroller-src/` as the project folder (it contains `platformio.ini`). Do not open the repo root in PlatformIO.

### Android app

Use JDK 17. Open `android-src/KV4PHT/` in Android Studio, or:

```bash
cd android-src/KV4PHT
./gradlew assembleDebug
```

Debug APK: `android-src/KV4PHT/app/build/outputs/apk/debug/app-debug.apk`.

### Hardware and other docs

- PCB files: `pcb/`
- 3D-printed cases: `3d-print-case/`
- Common problems: [FAQ.md](FAQ.md)
