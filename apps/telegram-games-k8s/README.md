# telegram-games-k8s

Telegram bot that lets authorized users restart game servers. Anyone can message the bot
and request access; a bootstrap admin approves them and is notified on each restart.
Source and image build live in the separate `telegram-games-k8s` repo; this directory
only holds the Flux/Helm deployment (bjw-s `app-template`).

## What gets deployed

| File | Purpose |
|------|---------|
| `namespace.yaml` | `telegram-games-k8s` namespace |
| `rbac.yaml` | ServiceAccount + **ClusterRole/Binding** (list + rollout-restart Deployments/StatefulSets in every namespace) |
| `storage.yaml` | 1Gi local-storage PV/PVC on `homeserver` for the SQLite DB (mounted at `/data`) |
| `secrets.yaml` | SOPS-encrypted `TELEGRAM_BOT_TOKEN`, `BOT_ADMINS` |
| `ghcr-pull-secret.yaml` | SOPS-encrypted dockerconfig to pull the private GHCR image |
| `helmrelease.yaml` | app-template release (long-polling, no Service/Ingress) |

Cluster-wide RBAC is used on purpose: each game runs in its own namespace
(`minecraft`, `satisfactory`, …), so the bot discovers and restarts across all of them.

## Before it works

1. **Set the real secrets** (needs the age key):
   ```sh
   sops apps/telegram-games-k8s/secrets.yaml
   ```
   Replace the placeholder bot token and the bootstrap admin user IDs (the admins who
   approve access requests). Admins must start a chat with the bot to get notifications.
   **Keep the values quoted** (e.g. `BOT_ADMINS: "13556577"`) — an unquoted number is
   parsed as an int and rejected by the Secret's `stringData` (Flux dry-run fails).

2. **Label the game servers** you want to manage. The bot only sees workloads carrying:
   ```yaml
   metadata:
     labels:
       games.telegram-bot/managed: "true"
       games.telegram-bot/name: "Minecraft"   # optional friendly name
   ```
   Add these labels to the `Deployment`/`StatefulSet` of each game (e.g. under
   `games/minecraft`, `games/satisfactory`).

3. **Image pull access.** The image is the private `ghcr.io/tobimichael96/telegram-games-k8s`.
   `ghcr-pull-secret.yaml` holds the dockerconfig (reusing the same GHCR credentials as the
   `sessionhoster` app) and the HelmRelease references it via
   `defaultPodOptions.imagePullSecrets`. The underlying token needs `read:packages`; if you
   rotate it, re-create this secret and `sessionhoster`'s the same way.

## Usage

Message the bot and `/request` access; an admin approves you (`/requests` or the
Approve button). Then `/servers` to pick a server and restart it. `/help` lists everything.
