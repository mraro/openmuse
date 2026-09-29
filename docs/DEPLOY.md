# Deploy to a VPS

Every push to `main` that passes CI builds three images, pushes them to GitHub
Container Registry (GHCR), and restarts the stack on your VPS over SSH.

```
push main → CI ✓ → Deploy workflow → ghcr.io/<owner>/openmuse-{api,web,browser-worker}:<sha>
                                   → ssh VPS → /opt/openmuse/deploy.sh → docker compose up
```

| Container | Image | Role |
| --- | --- | --- |
| `web` | Caddy + exported Expo web app | HTTPS on 80/443, serves the app, proxies `/api/*` |
| `api` | Node API (`pnpm build:server`) | API, CopilotKit runtime, task worker, PGlite in the `api-data` volume |
| `browser-worker` | `apps/worker` | Chromium with persistent profiles, reachable only from `api` |

Files: [`Dockerfile`](../Dockerfile), [`infra/compose.prod.yaml`](../infra/compose.prod.yaml),
[`infra/Caddyfile`](../infra/Caddyfile), [`infra/deploy.sh`](../infra/deploy.sh),
[`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml).

A public server must run `WORKSPACE_MODE=live`: sample mode has no sign-in and
refuses to bind outside loopback.

## 1. Prepare the VPS (once)

Ubuntu/Debian with 2 GB+ RAM (4 GB recommended for Chromium). Point your
domain's DNS A/AAAA record at the VPS and open ports 22, 80 and 443.

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

Create the production environment file:

```sh
sudo -u deploy nano /opt/openmuse/.env   # start from infra/.env.production.example
chmod 600 /opt/openmuse/.env
```

Generate secrets with `openssl rand -base64 32` (for `OPENMUSE_ACCESS_KEY`,
`TOKEN_ENCRYPTION_KEY` and `WORKER_TOKEN`). Set `DOMAIN` to the same value as the
GitHub variable below. For Google, register
`https://<DOMAIN>/api/google/callback` as the OAuth redirect URI.

## 2. Configure GitHub (once)

In **Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `DOMAIN` | `muse.example.com` (no scheme). The workflow is skipped until this is set. |
| Variable | `DEPLOY_PATH` | Optional, default `/opt/openmuse` |
| Secret | `VPS_HOST` | VPS IP or hostname |
| Secret | `VPS_USER` | `deploy` |
| Secret | `VPS_SSH_KEY` | The private key from step 1 |
| Secret | `VPS_PORT` | Optional, default `22` |
| Secret | `VPS_KNOWN_HOSTS` | Optional but recommended: output of `ssh-keyscan <host>` run from a trusted machine. Without it the first key seen is trusted. |

The workflow deploys to the `production` environment, so you can add required
reviewers there under **Settings → Environments** if you want a manual gate.

## 3. Deploy

Push to `main`, or run **Actions → Deploy → Run workflow**. The workflow waits
for every container to become healthy and then checks
`https://<DOMAIN>/api/health`. Open `https://<DOMAIN>` and sign in with
`OPENMUSE_ACCESS_KEY`.

For native apps, build with `EXPO_PUBLIC_API_URL=https://<DOMAIN>` and add their
origin to `ALLOWED_ORIGINS` if needed.

## Operations

```sh
cd /opt/openmuse
./deploy.sh                 # redeploy the current tag (e.g. after editing .env)
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
docker build --target web --build-arg PUBLIC_URL=https://<DOMAIN> -t openmuse-web:local .
docker build -t openmuse-browser-worker:local apps/worker
cd infra && cp .env.production.example .env   # fill it in
docker compose -f compose.prod.yaml up -d      # uses the :local tags
```
