# 3x-ui Selfhost Kit Handoff

## Subscription operation

- `/sub/` is the normal user-facing entry: it refreshes the current 3X-UI inbound links, then produces a Clash 3.5 short subscription automatically.
- The direct subscription is `/subscriptions/<SUBSCRIPTION_TOKEN>.b64`. The token is stored only in the server `.env` file.
- Domain-node mode maps every complete group of generated links back to `SERVER_ALIASES`. It must not expand an already grouped list again; a ten-domain, two-protocol deployment must publish 20 nodes, not 200.
- The public refresh endpoint is intentionally input-free and throttled by `PUBLIC_LINK_REFRESH_INTERVAL` (default 60 seconds). Configuration editing and forward management remain protected by `SUB_CONFIG_ADMIN_TOKEN`.

## Update and recovery

- Update an installed host with `curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/one-click.sh | sudo bash -s -- update`.
- The updater preserves `.env`, `data/db`, `data/backups`, and `site/sub/config/3.5.yaml`.
- Validate after an update with `./scripts/manage.sh refresh-links`, `docker compose ps`, and a client download of the generated short subscription.

## Sensitive handoff records

Do not commit credentials. On each deployment host, keep the actual panel account, subscription token, rules-editor token, API token, and backup locations in `/opt/3xui-selfhost-kit/runtime/install-summary.txt` and `/opt/3xui-selfhost-kit/.env` (both owner-readable only). Update those local records when credentials or endpoints change.
