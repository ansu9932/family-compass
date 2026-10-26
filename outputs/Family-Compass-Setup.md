# Family Compass 1.2.1

## Included

- iPhone parent app: saved device list supporting three or more Android phones, individual rename/remove, camera / screen / audio buttons per phone.
- Android child app: no login, internet binding code, phone name, guided camera/microphone/notification permission setup.
- Existing paired phone is migrated without replacing its key. Each newly paired phone receives an independent access key.
- Camera flip and connection progress remain available. One live session at a time on the parent.

## Add another Android phone

1. Install `Family-Compass-Child-1.2.1.apk` on the Android phone.
2. On iPhone, tap **Add device**. Leave this page open.
3. Enter the displayed binding code into the child app and name the phone. The code expires after 10 minutes.
4. Approve that phone on the iPhone.
5. Complete the Android permission checklist, then tap **Finish setup**.
6. Optionally enable **Allow this parent to start sessions** on Android. This saves app-level approval for that paired parent; Android permission prompts still apply.
7. On the iPhone, choose that phone's **Camera**, **Screen**, or **Audio**.

Both phones need internet. They do not need the same Wi-Fi. On Android, enable **Keep available when app screen is closed** and accept the on-device explanation. The persistent notification means the paired parent can request camera or microphone while the app screen is closed. Without this mode, keep the app open to receive requests. Android asks for screen-sharing confirmation for each new projection; locking the phone ends screen projection. Camera/microphone capture remains visible and can be stopped on Android. Notification access is an optional, separate setup for app-name/time summaries only. No accessibility or usage-history access is requested.

## Keep available

1. Open the Android child app once and enable **Keep available when app screen is closed**.
2. Read and accept the explanation; camera, microphone and notifications must be allowed. This also saves approval for the paired parent.
3. You can leave the app screen or remove it from Recents. An ongoing **Family Compass: available to parent** notification shows the service is running.
4. Camera and microphone requests may then start using that active foreground service. Their active-use indicators and notification remain visible. Stop from the notification or switch.
5. Screen sharing still requires a new Android approval. If the app screen is closed, tap the request notification and confirm Android's prompt. Requests expire after roughly 85 seconds.
6. After Force stop, a phone restart, or Android stopping the process, reopen the app and enable availability again. Pairing remains saved. Turning off the saved parent approval also stops availability. Changing pairing/setup stops the service.

This uses extra battery. Android sleep/battery policy and network conditions can delay requests; a one-second connection is not guaranteed. The service is visible and stoppable and does not restart itself after Force stop or bypass screen-capture consent.

## Service status

The user confirmed Camera and Audio work with the app screen closed on version 1.1.2. Version 1.1.3+9 separates screen projection from camera/audio availability to correct a service-type downgrade, requests up to 1080p camera capture with continuous autofocus, and adds connection recovery. Both release builds succeeded and version 1.1.3+9 is installed and launched on the connected Samsung and iPhone. The user confirmed the camera connects while Android is locked and the picture is clearer. Logs show actual 1920 × 1080 capture and encoded frames. Network-switch recovery remains unverified on the devices; no automated test suite was run. It uses the AWS Lightsail server in Mumbai, with encrypted HTTPS signaling and authenticated TURN fallback over UDP/TCP. The fixed IP is `35.154.20.53`; the service endpoint is `https://familycompass.35.154.20.53.sslip.io`.

The server services start automatically after a server restart. Pairing records stay on the phones. No camera, screen or audio recordings are stored on the server. The app uses direct encrypted WebRTC when possible and AWS TURN when necessary. Connection speed still depends on the phones and their networks; restrictive networks can still block the available ports.

The iPhone audio session is configured for playback, Android microphone permission is checked before capture, and permission errors are separated from connection errors. The parent shows whether audio packets are arriving. The user confirmed Audio works after installation of this version.

The hostname uses the public sslip.io DNS service and a valid automatically renewed Let's Encrypt certificate. The existing Lightsail plan is $7/month before taxes or transfer overage; TURN traffic uses the plan's transfer allowance. The old Cloudflare service was not deleted, but these new builds use AWS.

## Distribution

The Android APK uses the same development signing key as the earlier installed app for an in-place update. Keep that key for future updates. The iPhone app is development signed for the connected phone; Apple development provisioning can expire and require rebuilding. This is not an App Store distribution build.

## Camera quality and connection recovery

- After updating Android, open the child app and enable **Keep available when app screen is closed** again. An app update restarts the process; pairing and granted permissions remain saved.
- Camera capture requests 1080p at 30 fps and continuous autofocus where supported. The iPhone displays the actual received resolution/frame rate. Good light, a clean camera lens, and sufficient upload speed are still needed for a sharp image.
- The encoder may use up to 6 Mbps; actual quality and data use vary with the network. Slow connections cannot sustain full quality.
- Short network interruptions trigger up to three recovery attempts over 60 seconds in the same session. Both apps must be on version 1.1.3 for this recovery. Stop still ends the session.
- Internet access works through the existing AWS signaling and authenticated UDP/TCP TURN relay. No global availability or latency guarantee is made: offline/force-stopped phones, restrictive networks, and server/DNS outages can prevent access.

### Android autofocus correction

During the build 9 camera check, logs exposed a plugin argument mismatch: Dart sent `focusMode`, while Android read `mode`. The Android-only build 10 corrects that mismatch and accepts the old key for compatibility. The iPhone build 9 uses the same version 1.1.3 connection protocol. Final Android build 10 was successfully built, installed in place, and launched on the Samsung. The user confirmed both Camera (including flip) and Screen previews work on the final build. Logs confirm autofocus applied and 1920 × 1080 camera capture connected. The downloadable child APK contains build 10.


## Notification activity inbox and daily report — 1.2.0

1. Update both apps. On Android, open **Notification activity settings** (also available in Child setup).
2. Allow visible app notifications. Tap **Open** next to Android Notification access, read the explanation, then choose **Family Compass activity summaries** and grant access in Android Settings. Android may require **Allow restricted settings** in the app information menu for a sideloaded APK.
3. Return to Family Compass and explicitly enable **Share activity with paired parent**. A visible notification includes **Stop sharing**. Sharing is off by default. It can also be revoked in Android Notification access settings.
4. On iPhone, choose a phone → **Notification activity & daily report**. Filter by app, search app names, and choose **Today** or **Last 24 hours**.
5. Tap **Download daily report (.txt)** → **Save to Files** for a daily snapshot of the current filters, per-app counts and arrival times.

Only app names/packages and new-notification arrival times are collected. The implementation does not read notification text, senders, OTPs, actions or images. Ongoing notifications, group summaries and repeated updates to an existing notification are excluded. OS restrictions and offline periods can cause omissions or delays; this is not an exact message counter.

Summaries are encrypted on Android before entering its private offline queue and remain encrypted on AWS. The inbox refreshes every two seconds while visible, and catches up after reopening; iOS background push alerts are not implemented. Android retries offline uploads while records are younger than 24 hours. Records expire from the original arrival time, even when uploaded late. Expired records are excluded immediately from relay reads and uploads; the server sweeps storage every minute and Android purges on use/background cleanup. OS suspension can delay physical cleanup on a powered-off or force-stopped phone. Parent history is held only in memory. Re-pairing or stopping sharing clears the Android queue; already received summaries expire normally.

Exported files are user-owned copies and are **not** automatically erased after 24 hours. Temporary iOS export files are removed after the share sheet closes and any leftovers are removed on next launch. This feature does not hide the child app or change uninstall permissions.

## Battery and internet indicators — 1.2.0

Each parent device card shows battery percentage, charging/plugged-in status, and the current Wi-Fi/mobile-data/other network type. Reports are encrypted and sent approximately every 10 seconds while the child Flutter app is running, including its visible Keep available mode. Parent cards show the last update and mark observations stale after 45 seconds. A stopped/offline phone cannot provide live readings. The cellular icon indicates mobile data, not measured signal strength or tower location. No phone-number, SSID or location permission is added.


## Release evidence — 24 October 2026

Both release builds completed as **1.2.0+11**. The Samsung installed and launched the update; its package reports versionName 1.2.0/versionCode 11. The existing visible availability service is running, and the AWS relay is receiving a live encrypted device-status record. No new app crash appeared in the current Android process log inspected after launch. The iPhone install succeeded; automatic launch was blocked by the lock screen, so unlocking/opening it remains an on-device step.

AWS reports service version 1.2.0 over HTTPS, and familycompass/Caddy/coturn services are active. Notification access, first activity delivery, on-iPhone status rendering, and export still need the user's first-use confirmation. No synthetic notifications or automated test suite were run. Build logs: `work/build-activity-android.log`, `work/build-activity-ios.log`. Android artifact: `Family-Compass-Child-1.2.0.apk`; checksum file is alongside it.


## Android 1.2.1: activity fix and app PIN

The activity queue's SQLite configuration now uses a query for the `secure_delete` PRAGMA, which returns a row. The earlier command-only call caused activity settings/queue initialization to fail. A successful settings refresh also clears stale error text.

Finish Child setup and create a **six-digit app PIN** directly on the Android phone. Existing installations without a PIN return to Child setup after this update. Keep this PIN private; do not send it in chat. The PIN gate covers all child-app routes when the Activity is reopened, while already authorized visible background sharing can continue. Use **Change app PIN** in the child app to change it with the current PIN.

PIN verification uses a random salt, PBKDF2, Android Keystore-protected storage, and a persisted retry delay after repeated failed attempts. The PIN is not transmitted to the relay or parent. Android 8+ uses PBKDF2-HMAC-SHA256; the Android 7 compatibility path uses PBKDF2-HMAC-SHA1 with a higher iteration count. There is no app-defined uninstall password, device administrator enrollment, or removal prevention. Android system controls remain available. Resetting forgotten PIN protection through Android app-data settings removes local pairing/settings and requires pairing again.

The lock screen includes **Stop all sharing — no PIN needed**. This stops media/availability, clears queued activity and pauses device-status reports until explicitly resumed. Unlock and enable Keep available or activity sharing to resume the relevant feature. Existing Android notifications also retain Stop controls.

The iPhone parent version 1.2.0+11 remains protocol-compatible with Android 1.2.1+12; no relay change is needed for this Android correction. Activity summaries appear in the in-app inbox while it is open; iOS push notifications are not part of this version.


### 1.2.1 installation evidence

Android release build succeeded and installed on the Samsung as version 1.2.1/build 12. After launch, the activity settings page successfully showed Notification access **Granted** and **Sharing is on — 0 waiting to sync**, without the previous settings error. The iPhone parent app was opened successfully after the user unlocked it. The user confirmed PIN creation; first end-to-end activity receipt remains unconfirmed; no synthetic notification or automated suite was run. Build log: `work/build-pin-android.log`.


### Reinstallation and APK cleanup — 24 October 2026

The user removed the Android app and requested reinstallation. Version 1.2.1/build 12 was reinstalled successfully on the Samsung and launched. Uninstalling cleared the old child pairing, permissions and PIN, so complete pairing and setup again. The PIN protects opening child-app controls; Android uninstall remains available. Older Family Compass APKs and their obsolete checksum files were deleted from this project’s output folder. The current download is `Family-Compass-Child-1.2.1.apk`.
