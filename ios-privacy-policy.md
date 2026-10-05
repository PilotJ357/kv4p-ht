# Pocket HT for iOS — Privacy Policy

Effective October 5, 2026

Pocket HT is an open-source app for controlling a kv4p HT amateur radio over Bluetooth.
The full source code is public, so everything below can be checked against the code.

## The short version

- No accounts, ads, analytics, tracking, or third-party SDKs.
- The app itself makes no internet requests. Nothing is sent to the developer.
- Your settings and history stay on your device.
- **Anything you transmit on the radio is public.** That includes voice, APRS messages, and,
  if you turn it on, your position.

## What stays on your device

Your callsign and other settings, saved memory channels, notification preferences, and the
history of APRS packets sent and received are stored on your device only. This data is removed
when you delete the app. Like other app data, it can be included in your device's iCloud or
computer backups.

## Location

The app asks for location access only when you turn on a feature that needs it:

- **APRS position beacons.** Off by default. Before the first beacon, the app explains what
  will be broadcast and asks you to agree.
- **Notification distance filter.** Your location is compared on the device to positions in
  received APRS packets, so you are only notified about nearby stations.
- **Center map on me.** Tapping the location button on the Map tab centers the map on your
  position.

If location access is allowed, the map also shows where you are. Your location is never
sent to the developer or any server by the app.

## What you transmit is public

Amateur radio transmissions are not private and, by law, cannot be encrypted.

- **Voice.** When you press push-to-talk, microphone audio is transmitted over the radio.
  Anyone tuned to that frequency can hear it. The app does not record or store it.
- **APRS messages.** Messages and acknowledgments you send are broadcast along with your
  callsign.
- **APRS position beacons.** When enabled, your callsign and GPS position are broadcast at the
  interval you choose while the radio is connected and the app is open; they pause in the
  background, and are never sent with an out-of-date location. "Approximate position" rounds
  your location to about 1 km first.

APRS transmissions can be received by anyone nearby. Internet gateways (iGates) run by other
radio operators relay them to the APRS-IS network, and public websites such as aprs.fi display
and archive them. Once something has been transmitted, neither you nor the developer can
remove it. You can turn beaconing off and withdraw consent at any time under
More › My position & beacon.

## Live captions

Live captions turn received radio audio into text using Apple's speech recognition, which
runs **entirely on your device**. If your device or language doesn't support on-device
recognition, captions stay off. Audio is never sent to Apple's servers or anywhere else.
Captions are only saved if you turn on **Save transcripts** in Settings; saved transcripts
(text, frequency, and time) are stored on your device only, can be deleted from the
Transcript log at any time, and are removed when you delete the app. Audio is never saved.

## Other device features

- **Bluetooth** is used only to connect to your kv4p HT radio.
- **Notifications and Live Activities** for APRS traffic are created on your device. No
  push-notification server is involved.
- **Maps** are provided by Apple MapKit. To draw the map, Apple's servers receive the map
  area you are viewing, as described in Apple's privacy policy. The app sends nothing else.

## Children

The app is not directed at children. Transmitting requires an amateur radio license.

## Changes & contact

Changes to this policy will be posted with a new effective date. Questions or concerns:
[open an issue on GitHub](https://github.com/PilotJ357/kv4p-ht/issues).
