# Family Compass

Private source repository for the iPhone parent app, Android child app, and internet relay.

## Project layout

- `outputs/familycompass/`: Flutter app, Android/iOS integrations, and the locally patched flutter_webrtc package (including its upstream license).
- `outputs/familycompass-aws/`: current Python/AWS relay and service configuration.
- `outputs/familycompass-relay/`: earlier Cloudflare Worker relay and migrations.
- `outputs/Family-Compass-Setup.md`: device setup, release history, and known limitations.

## Build and configuration

See the README in each component. Mobile deployment configuration, credentials, signing keys, recordings, device logs, build output and APKs are intentionally excluded. Obtain private configuration separately from the project owner; never commit it. The existing mobile build uses a private Dart define file outside the tracked source. Provision your own iOS signing identity when building on another machine.

## Sharing controls

Media sharing is visible and stoppable on the child device. Android screen-capture approval is required for each new session. Notification activity is opt-in and includes app names and arrival times, not message contents. The app PIN protects app controls and does not prevent uninstall or stopping sharing.

## Verification status

This upload preserves the existing implementation. No new functional tests were run for repository creation. Refer to the setup guide for device-confirmed behavior and outstanding checks.

### iOS binary dependency

The vendored WebRTC Swift Package references `ios/flutter_webrtc/WebRTC.xcframework`. This downloaded binary is excluded from Git. Before using Swift Package Manager on a fresh checkout, restore WebRTC-SDK version `150.7871.01` to that path from its upstream distribution. The CocoaPods specification declares the same SDK version as a dependency. Existing local SDK files have not been deleted.
