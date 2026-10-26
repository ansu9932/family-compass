# Family Compass media relay

This Cloudflare Worker carries short-lived, end-to-end encrypted WebRTC signaling. Audio/video media travels directly between phones when possible, or through Cloudflare Realtime TURN when carrier NAT or firewall rules block a direct route. Neither signaling envelopes nor media are decrypted by this Worker. D1 stops serving an envelope after one hour; the daily cleanup removes expired encrypted rows later.

## Create the Worker and D1 database

The Wrangler account needs permission to create a Worker, create/update D1 databases, upload Worker secrets, and deploy Worker code. From this directory:

```sh
wrangler d1 create familycompass-media
```

Put the returned database ID into `wrangler.jsonc`, then apply the migration and deploy the Worker:

```sh
wrangler d1 migrations apply familycompass-media --remote
wrangler deploy
```

## Configure TURN credentials

Create a TURN key in the Cloudflare dashboard. Add its key ID and server-side API token as Worker secrets; do not put them in the phone app or source control:

```sh
wrangler secret put TURN_KEY_ID
wrangler secret put TURN_API_TOKEN
```

The Worker exchanges the long-lived token for four-hour ICE credentials only when a paired device requests a session. Those short-lived credentials are used by WebRTC for direct connectivity and TURN fallback. Without these secrets, the Worker returns STUN only; some carrier and Wi-Fi networks will fail to connect.

## Build and install the phone apps

Use the deployed Worker's `workers.dev` URL as `FC_RELAY_URL` in both app builds. Build/install commands and the no-account pairing flow are in `../familycompass/README.md`.

Cloudflare Realtime TURN can incur charges when traffic is relayed. Review the current account pricing before leaving sessions running.

## Local development

```sh
wrangler d1 migrations apply familycompass-media --local
wrangler dev
```

The production deployment requires a real D1 database ID in `wrangler.jsonc`; the local development server uses Wrangler's local D1 database.
