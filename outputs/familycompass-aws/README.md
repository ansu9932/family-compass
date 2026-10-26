# Family Compass AWS relay

Private deployment: Ubuntu Lightsail, Caddy HTTPS, Python encrypted mailbox service, coturn fallback. This service holds only encrypted signaling for up to one hour and does not record camera, screen, or audio. Pairing keys stay on phones.

- API compatibility: `/health`, `/v1/rooms/{room}/{parent|child}`, `/v1/rooms/{room}/ice-servers`.
- Each private app build supplies a deployment access key plus its per-pair derived bearer token. The deployment key limits casual relay abuse; it is not a substitute for the pair secret and can be extracted from an APK. Do not distribute the private build publicly.
- TURN uses four-hour HMAC credentials, allocation and bandwidth limits, and blocks private/reserved peer networks. Media remains WebRTC encrypted.
- Services restart with the server. Phones retain pairings across restarts, but must be powered on, online, and running the child app. Android screen-capture consent remains mandatory for each new session.
- Deployment secrets are stored outside this folder under `work/private` and on the server in restricted configuration files. Do not publish them.

## Deployed instance

- Lightsail `familycompass-relay`, Mumbai ap-south-1a, Ubuntu 24.04.
- Static IPv4 `35.154.20.53`, resource `familycompass-static`.
- HTTPS `https://familycompass.35.154.20.53.sslip.io`; sslip.io supplies public DNS; Let's Encrypt certificate renews through Caddy.
- Public TCP 80 (redirect/ACME), 443 (HTTPS), 3478 (TURN); UDP 3478 and 49160-49200. Existing SSH rule retained. TURN listens on the private IPv4 with its external mapping.
- Private app service binds only `127.0.0.1:8080`; Caddy admin binds only loopback.
- Units `familycompass`, `caddy`, `coturn` are enabled and active.
- App service source `/opt/familycompass/server.py`; encrypted mailboxes `/var/lib/familycompass/mailboxes.sqlite3`; secret environment `/etc/familycompass.env`; TURN configuration `/etc/turnserver.conf`.
- Plan remains the approved $7/month before taxes and transfer overage. TURN media uses server transfer allowance.

## Deployment evidence

HTTPS health returned 200 with certificate verification successful. Both release builds succeeded and were installed as version 1.1.1 build 7. Both apps launched. The user confirmed Audio works on the updated iPhone. Camera and screen were previously reported working; they have not been rechecked after this AWS migration. No automated test suite was run.

## Maintenance

Use the existing Lightsail default Mumbai SSH key from the Mac, with username `ubuntu`. Do not include the key in shared artifacts. Services can be inspected with `systemctl status familycompass caddy coturn`. Logs intentionally omit signaling bodies and credentials. Keep the private app APK limited to your own family devices; protect the deployment access key. Changing that key requires rebuilding both apps.


## 1.2.0 activity and device status

The same service now includes an authenticated, bounded `/activity` event queue for encrypted app-name/time summaries. Rows expire 24 hours after capture; reads exclude expired rows and a one-minute sweeper deletes them. SQLite secure deletion is enabled and WAL checkpoints retire old pages. No notification contents are collected by the client. `/status` uses the existing encrypted mailbox format with a 60-second server TTL for battery/charging/network observations. App history is not backed up by this deployment.

The previous server source is retained at `/opt/familycompass/server.py.pre-1.2.0`. A code rollback does not require restoring the database; the new table can remain unused. Firewall, billing plan, TLS configuration and TURN settings were not changed.
