# Deploy to a VPS

Every push to `main` that passes CI builds three images, pushes them to GitHub
Container Registry (GHCR), and restarts the stack on your VPS over SSH.

```
push main → CI ✓ → Deploy workflow → ghcr.io/<owner>/openmuse-{api,web,browser-worker}:<sha>
                                   → ssh VPS → /opt/openmuse/deploy.sh → docker compose up
```

| Container | Image | Role |
| --- | --- | --- |
| `web` | Caddy + exported Expo web app | HTTPS on the chosen network, serves the app, proxies `/api/*` |
| `api` | Node API (`pnpm build:server`) | API, CopilotKit runtime, task worker, PGlite in the `api-data` volume |
| `browser-worker` | `apps/worker` | Chromium with persistent profiles, reachable only from `api` |

Files: [`Dockerfile`](../Dockerfile), [`infra/compose.prod.yaml`](../infra/compose.prod.yaml)
(plus `compose.tailnet*.yaml`), [`infra/Caddyfile`](../infra/Caddyfile),
[`infra/deploy.sh`](../infra/deploy.sh), [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml).

## Choose the network

`./deploy.sh` asks once which network answers OpenMuse and saves the answer in
`.env` (`./deploy.sh --configure` changes it later):

| Mode | Listens on | HTTPS | Reached by |
| --- | --- | --- | --- |
| `tailnet` (default) | The VPS's Tailscale IPs only | Certificate from Tailscale for `<machine>.<tailnet>.ts.net` | Devices in your tailnet |
| `public` | Every interface, ports 80 and 443 | Let's Encrypt for your domain | Anyone on the internet |
| `local` | `127.0.0.1:<port>`, plain HTTP | Your own proxy or SSH tunnel | Only the VPS itself |

The server always runs `WORKSPACE_MODE=live`: sample mode has no sign-in.

## 1. Prepare the VPS (once)

Ubuntu/Debian with 2 GB+ RAM (4 GB recommended for Chromium).

- **tailnet:** install Tailscale and join it (`curl -fsSL https://tailscale.com/install.sh | sh`
  then `sudo tailscale up`). In the [admin console](https://login.tailscale.com/admin/dns)
  enable MagicDNS and **HTTPS Certificates**. No public port is needed besides SSH.
- **public:** point your domain's DNS A/AAAA record at the VPS and open ports 80 and 443.

```sh
# As root
curl -fsSL https://get.docker.com | sh
adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy
mkdir -p /opt/openmuse && chown deploy:deploy /opt/openmuse

# Deploy key: GitHub Actions uses it to log in as "deploy"
su - deploy -c 'mkdir -p ~/.ssh && ssh-keygen -t ed25519 -N "" -f ~/.ssh/github_deploy \
  && cat ~/.ssh/github_deploy.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
cat /home/deploy/.ssh/github_deploy   # copy this private key into VPS_SSH_KEY, then delete the file
```

Copy the stack files from your clone of this repository and run the guided setup
as `deploy`:

```sh
scp infra/compose.prod.yaml infra/compose.tailnet*.yaml infra/deploy.sh \
  infra/.env.production.example deploy@<vps>:/opt/openmuse/
ssh -t deploy@<vps> /opt/openmuse/deploy.sh
```

It asks for the network, then for every missing value: model and provider key,
CopilotKit Intelligence key, and the secrets (press Enter to generate them; the
sign-in access key is printed once). Everything is saved to
`/opt/openmuse/.env` with mode 600. In tailnet mode it can also set
`net.ipv4.ip_nonlocal_bind=1` so Docker can bind the Tailscale IP after a
reboot even if it starts before Tailscale. For Google, register
`<PUBLIC_URL>/api/google/callback` as the OAuth redirect URI.

The GitHub deploy never asks: if a value is missing it stops and names it.

## 2. Configure GitHub (once)

In **Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `DEPLOY_ENABLED` | `true`. The workflow is skipped until this is set. |
| Variable | `DEPLOY_PATH` | Optional, default `/opt/openmuse` |
| Secret | `VPS_HOST` | VPS IP or hostname |
| Secret | `VPS_USER` | `deploy` |
| Secret | `VPS_SSH_KEY` | The private key from step 1 |
| Secret | `VPS_PORT` | Optional, default `22` |
| Secret | `VPS_KNOWN_HOSTS` | Optional but recommended: output of `ssh-keyscan <host>` run from a trusted machine. Without it the first key seen is trusted. |
| Secret | `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` | Optional: when set, the runner joins your tailnet as `tag:ci` before SSH, so `VPS_HOST` can be the VPS's Tailscale name and SSH can be closed to the internet. Create the OAuth client (scope `auth_keys`, tag `tag:ci`) in the Tailscale admin console and allow `tag:ci` to reach the VPS on port 22 in your ACLs. |

The workflow deploys to the `production` environment, so you can add required
reviewers there under **Settings → Environments** if you want a manual gate.

## 3. Deploy

Push to `main`, or run **Actions → Deploy → Run workflow**. `deploy.sh` waits
for every container to become healthy and then checks `<PUBLIC_URL>/api/health`
from the VPS itself (a GitHub runner cannot reach a tailnet-only site). Open
`PUBLIC_URL` (shown by `deploy.sh`) and sign in with `OPENMUSE_ACCESS_KEY`.

The web image calls the API on whatever origin serves it, so one image works in
every mode. For native apps, build with `EXPO_PUBLIC_API_URL=<PUBLIC_URL>` and
add their origin to `ALLOWED_ORIGINS` in `.env` if needed.

## Operations

```sh
cd /opt/openmuse
./deploy.sh                 # redeploy the current tag (e.g. after editing .env)
./deploy.sh --configure     # switch between tailnet, public and local
./deploy.sh <12-char-sha>   # roll back or forward to a pushed commit
docker compose --env-file .env --env-file .deploy.env -f compose.prod.yaml logs -f api
```

Old images stay on the VPS for a week, so a recent rollback needs no registry
access. For older tags from a private repository, first run
`docker login ghcr.io` with a token that has `read:packages`.

Back up the Docker volumes `openmuse_api-data` (database, documents, signing
key) and `openmuse_browser-profiles`. Caddy certificates live in
`openmuse_caddy-data`.

The optional Docker Linux computer (`COMPUTER_ENABLED`) is not wired into this
stack: it needs the host Docker socket, which would give the API root on the
VPS. Leave it disabled or see [COMPUTER.md](COMPUTER.md) before enabling it.

## Build locally

```sh
docker build --target api -t openmuse-api:local .
docker build --target web -t openmuse-web:local .
docker build -t openmuse-browser-worker:local apps/worker
cd infra && echo IMAGE_TAG=local > .deploy.env && ./deploy.sh   # uses the :local tags
```
