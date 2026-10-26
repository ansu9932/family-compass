# Family Compass

Android version 1.2.1+12 (compatible iPhone 1.2.0+11): iPhone parent dashboard and Android child setup for camera, screen mirroring, and one-way audio. See [setup guide](../Family-Compass-Setup.md).

## Architecture

- `main.dart`: platform-specific parent dashboard or child pairing / permissions / ready screen.
- `device_store.dart`: secure per-device records and migration of the previous single-device pair.
- `internet_pairing.dart`: 100-bit random invitation, 10-minute lifetime, explicit parent approval, encrypted key exchange through existing relay. Every new pair gets an independent 240-bit key.
- `remote_media.dart`: existing WebRTC media with visible capture, optional saved child approval, camera flip, progress and stop controls.
- `internet_signal.dart`: AES-256-GCM encrypted signaling with per-room authentication.
- Native Android methods: runtime camera, audio and notification permission setup; lock state; capture foreground service.

No account login, accessibility service, usage-history permission, or location UI. Pairing works over the internet. Parent stores credentials in iOS Keychain; child stores its pairing key using secure storage. Upgrades preserve the app identifier and existing pair. Android APK is development signed for compatibility with earlier installs.

## Build

```sh
flutter pub get
flutter build apk --release --dart-define-from-file=../../work/private/aws-build.json
flutter build ios --release --dart-define-from-file=../../work/private/aws-build.json
```

The vendored flutter_webrtc package retains the Android 14+ media-projection foreground-service fix. Release iOS signing uses the existing configured development team. A physical temporary copy avoids extended-attribute signing problems in the Documents directory.

## Current limits

The child phone must be online. Its screen can be closed while the opt-in, visible Keep available service is running. After Force stop/restart/process death, the user must reopen it and enable availability again. Android confirmation is required for each new screen projection. Only one parent-viewing session runs at a time. AWS HTTPS signaling and authenticated UDP/TCP TURN fallback are deployed. Network conditions still determine connection speed. iPhone playback configuration and stage-specific audio errors are included; the user confirmed Audio works on version 1.1.1. Deployment configuration and source are in `../familycompass-aws`. Build secrets stay in the private build configuration and must not be published.


## Availability lifecycle

Android `MediaRuntime` retains a single Flutter engine across Activity destruction. The user explicitly starts a camera/microphone foreground availability service while the Activity is visible and runtime permissions are granted. A notification exposes availability, active capture, and Stop. No boot receiver, sticky restart, permission bypass, hidden icon, or accessibility capture is used. Camera/audio use saved approval from this paired parent; screen requests without a visible Activity use a notification and await Android's standard consent flow.

The service is `START_NOT_STICKY` and `stopWithTask=false`. Android may still stop it. The parent displays when child action is required. Stop closes media before network signaling. In-flight capture completion is checked against a cancellation revision to avoid starting capture after it was stopped.

## Version 1.1.3 changes

- Camera/microphone availability and screen projection use separate native services. A screen request no longer changes camera/audio service types or stops availability. Screen-service binding failure returns an error.
- The camera requests 1920 × 1080 at 30 fps; native format selection uses the nearest supported size. Continuous autofocus is reapplied when starting or switching cameras where supported. The sender allows up to 6 Mbps with resolution preference; bandwidth and device capacity can still reduce received quality.
- The parent shows received frame size and frame rate. Camera-open failure no longer returns an apparently working empty video track.
- Existing sessions attempt up to three ICE restarts within a 60-second recovery window after connection loss, using refreshed authenticated TURN credentials. Recovery preserves the active capture and its consent; it does not recreate a stopped screen projection. A stopped/offline device cannot be accessed.
- Child build 9 needs parent build 9 for the new recovery signaling. Existing pairing records and AWS endpoint are unchanged.

The build 9 user check confirmed locked-screen camera connection and a clearer image; logs showed 1920 × 1080 capture/encoding. Android build 10 additionally fixes the native autofocus argument name (`focusMode`) and retains compatibility with `mode`.

Final Android build 10 installed and launched successfully. The user confirmed both Camera/flip and Screen previews work. Runtime logs show autofocus applied and 1920 × 1080 capture. iPhone remains compatible build 9. Network handoff recovery was implemented and compiled but has not been manually verified.


## Version 1.2.0

- `notification_activity.dart`: opt-in child setup and parent per-device activity inbox, app/search/time filters, per-app counts, and a daily plain-text export via the iOS share sheet.
- Android `ActivitySharing.kt`: standard NotificationListenerService, visible status/Stop control, metadata-only collection, encrypted private offline queue, JobScheduler retry and expiry. Notification contents are never read. Android Keystore wraps upload configuration; a separate HMAC-derived AES-GCM key protects summaries end to end. Pairing change/stop discards the queue.
- AWS `/activity`: authenticated paginated encrypted event store, idempotent IDs, 24-hour expiry from capture time, periodic cleanup, per-room/global bounds. Existing media mailboxes and TURN are unchanged.
- `DeviceStatus.kt` and `phone_status.dart`: encrypted battery/charging/network reports every ten seconds while the existing child runtime is available. Parent labels old readings with their last update instead of presenting them as live.
- iOS export staging files use complete file protection and are removed after sharing. User-saved reports are outside automatic app expiry.

No APNs/background iOS notification alerts are included. Activity updates, group summaries and ongoing notifications are excluded from counts. Offline records are retried until expiry. Android force-stop, sleep policy or revoked permissions can interrupt delivery. No automated test suite was run for this release; build/install evidence and manual status are recorded in the setup guide.


## Android 1.2.1

Corrects SQLite PRAGMA invocation during activity database initialization. `ChildPin.kt` adds local PBKDF2/Keystore PIN verification with a persisted cooldown; `child_pin.dart` covers the Navigator with a PIN gate and provides setup/change UI. MainActivity locks the gate on pause. Existing installations without a PIN return to setup. A PIN-free Stop action pauses media, metadata reporting and activity sharing; it does not prevent access to Android settings or uninstall. No device-admin, accessibility, removal-blocking or hidden-launcher components were added.
