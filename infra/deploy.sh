#!/usr/bin/env bash
# Runs on the VPS. Checks .env, pulls the images for IMAGE_TAG and restarts the stack.
#
#   ./deploy.sh                 redeploy the tag recorded in .deploy.env
#   ./deploy.sh <tag>           deploy (or roll back to) another pushed tag
#   ./deploy.sh --configure     choose the network again (public, tailnet or local)
#
# Run it by hand once: in a terminal it asks for the network and for every
# missing setting, then saves the answers to .env. Without a terminal (the
# GitHub deploy) it never asks and stops if something is missing.
set -euo pipefail
cd "$(dirname "$0")"

RECONFIGURE=false
TAG=""
for arg in "$@"; do
  case "$arg" in
    --configure) RECONFIGURE=true ;;
    -h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *) TAG="$arg" ;;
  esac
done

INTERACTIVE=false
[ -t 0 ] && [ -t 1 ] && INTERACTIVE=true
MISSING=()

if $INTERACTIVE; then B=$'\033[1m' Y=$'\033[33m' R=$'\033[31m' N=$'\033[0m'; else B='' Y='' R='' N=''; fi
say() { printf '%s%s%s\n' "$B" "$*" "$N"; }
warn() { printf '%s! %s%s\n' "$Y" "$*" "$N" >&2; }
die() { printf '%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

# --- .env helpers ----------------------------------------------------------

if [ ! -f .env ]; then
  $INTERACTIVE || die "Missing $(pwd)/.env. Run ./deploy.sh once in a terminal on the VPS to create it."
  if [ -f .env.production.example ]; then cp .env.production.example .env; else : > .env; fi
  say "Created $(pwd)/.env"
fi
chmod 600 .env

get_env() {
  local line
  line=$(grep -E "^$1=" .env | tail -n 1) || true
  line=${line#*=}
  line=${line%%[[:space:]]#*}
  line=${line%"${line##*[![:space:]]}"}
  case "$line" in \"*\" | \'*\') line=${line:1:${#line}-2} ;; esac
  printf '%s' "$line"
}

set_env() {
  local key=$1 value=$2 tmp
  case "$value" in *[[:space:]\#\"\$]*) value="'${value//\'/}'" ;; esac
  tmp=$(mktemp .env.XXXXXX)
  grep -vE "^$key=" .env > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" .env
}

# ask KEY "Question" [default] [secret]
# Keeps the current value; asks only when it is empty (or on --configure for network keys).
ask() {
  local key=$1 question=$2 default=${3:-} secret=${4:-} value
  if ! $INTERACTIVE; then
    # Never invent a secret nobody has seen; only plain defaults are filled in.
    if [ -n "$default" ] && [ "$secret" != secret ]; then set_env "$key" "$default"; else MISSING+=("$key"); fi
    return
  fi
  while :; do
    if [ "$secret" = secret ]; then
      read -r -s -p "$question${default:+ [Enter = generate]}: " value; echo
    else
      read -r -p "$question${default:+ [$default]}: " value
    fi
    if [ -z "$value" ] && [ -n "$default" ]; then
      value=$default
      [ "$key" = OPENMUSE_ACCESS_KEY ] && say "Your sign-in access key: $value (saved in .env)"
    fi
    [ -n "$value" ] && break
    warn "A value is required."
  done
  set_env "$key" "$value"
}

need() { # need KEY "Question" [default] [secret]
  [ -n "$(get_env "$1")" ] || ask "$@"
}

random() { openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-"$1"; }

# --- Network ---------------------------------------------------------------

tailscale_field() { tailscale status --json 2>/dev/null | tr -d ' \n' | grep -o "\"$1\":\"[^\"]*\"" | head -n 1 | cut -d'"' -f4; }

configure_network() {
  local current choice
  current=$(get_env NETWORK_MODE)
  if [ -n "$current" ] && ! $RECONFIGURE; then return; fi
  if ! $INTERACTIVE; then
    [ -n "$current" ] || MISSING+=("NETWORK_MODE")
    return
  fi

  say "Which network should answer OpenMuse?"
  echo "  1) tailnet  - only devices on your Tailscale network (HTTPS from Tailscale)"
  echo "  2) public   - the whole internet on a domain (HTTPS from Let's Encrypt)"
  echo "  3) local    - only 127.0.0.1, plain HTTP (behind another proxy or an SSH tunnel)"
  case "$current" in public) choice=2 ;; local) choice=3 ;; *) choice=1 ;; esac
  read -r -p "Choice [$choice]: " reply
  case "${reply:-$choice}" in
    1 | tailnet) configure_tailnet ;;
    2 | public) configure_public ;;
    3 | local) configure_local ;;
    *) die "Choose 1, 2 or 3." ;;
  esac
}

configure_tailnet() {
  command -v tailscale >/dev/null || die "Tailscale is not installed. Install it (curl -fsSL https://tailscale.com/install.sh | sh), run 'sudo tailscale up', then run ./deploy.sh again."
  local ip4 ip6 name port
  ip4=$(tailscale ip -4 2>/dev/null | head -n 1) || true
  [ -n "$ip4" ] || die "Tailscale is not connected. Run 'sudo tailscale up' first."
  ip6=$(tailscale ip -6 2>/dev/null | head -n 1) || true
  # Publish on IPv6 only when the host really has that address.
  if [ -n "$ip6" ] && command -v ip >/dev/null && ! ip -6 addr show 2>/dev/null | grep -qiF "$ip6"; then ip6=""; fi
  [ -s /proc/net/if_inet6 ] || ip6=""
  name=$(tailscale_field DNSName); name=${name%.}
  [ -n "$name" ] || die "No MagicDNS name found. Enable MagicDNS in the Tailscale admin console."
  if ! tailscale status --json 2>/dev/null | tr -d ' \n' | grep -q "\"CertDomains\":\[\""; then
    warn "HTTPS certificates are off for this tailnet. Enable them at"
    warn "https://login.tailscale.com/admin/dns (HTTPS Certificates), or the site will not load."
  fi
  read -r -p "HTTPS port on the tailnet [443]: " port
  port=${port:-443}
  set_env NETWORK_MODE tailnet
  set_env DOMAIN "$name"
  set_env BIND_ADDRESS "$ip4"
  set_env BIND_ADDRESS6 "$ip6"
  set_env HTTPS_PORT "$port"
  set_env HTTP_PORT 80
  set_env SITE_ADDRESS "$name$( [ "$port" = 443 ] || printf ':%s' "$port")"
  set_env PUBLIC_URL "https://$name$( [ "$port" = 443 ] || printf ':%s' "$port")"
  say "Answering only on $ip4${ip6:+ and $ip6} (Tailscale) as $(get_env PUBLIC_URL)"
  offer_nonlocal_bind
}

configure_public() {
  local domain current
  current=$(get_env DOMAIN)
  [ "$(get_env NETWORK_MODE)" = public ] || current=""
  read -r -p "Domain (DNS already pointing at this VPS)${current:+ [$current]}: " domain
  domain=${domain:-$current}
  domain=${domain#https://}; domain=${domain%%/*}
  [ -n "$domain" ] && [ "$domain" != muse.example.com ] || die "A real domain is required for public mode."
  set_env NETWORK_MODE public
  set_env DOMAIN "$domain"
  set_env BIND_ADDRESS 0.0.0.0
  set_env BIND_ADDRESS6 ""
  set_env HTTPS_PORT 443
  set_env HTTP_PORT 80
  set_env SITE_ADDRESS "$domain"
  set_env PUBLIC_URL "https://$domain"
  say "Answering on every interface as https://$domain (ports 80 and 443 must be open)"
}

configure_local() {
  local port url
  read -r -p "HTTP port on 127.0.0.1 [8080]: " port
  port=${port:-8080}
  read -r -p "URL people will open (through your proxy or tunnel) [http://localhost:$port]: " url
  url=${url:-http://localhost:$port}
  url=${url%/}
  set_env NETWORK_MODE local
  set_env DOMAIN "$(printf '%s' "$url" | sed -E 's#^[a-z]+://##; s#[:/].*##')"
  set_env BIND_ADDRESS 127.0.0.1
  set_env BIND_ADDRESS6 ""
  set_env HTTP_PORT "$port"
  set_env HTTPS_PORT 8443
  set_env SITE_ADDRESS "http://"
  set_env PUBLIC_URL "$url"
  say "Answering only on 127.0.0.1:$port as $url"
}

# Docker binds to the Tailscale address when the stack starts. After a reboot
# Docker can start before Tailscale; nonlocal bind lets it bind anyway.
offer_nonlocal_bind() {
  [ "$(cat /proc/sys/net/ipv4/ip_nonlocal_bind 2>/dev/null)" = 1 ] && return
  local sudo=""
  [ "$(id -u)" = 0 ] || sudo=sudo
  read -r -p "Allow Docker to start before Tailscale after a reboot (sysctl ip_nonlocal_bind, needs sudo)? [Y/n]: " reply
  case "${reply:-y}" in
    [yY]*)
      printf 'net.ipv4.ip_nonlocal_bind = 1\nnet.ipv6.ip_nonlocal_bind = 1\n' |
        $sudo tee /etc/sysctl.d/60-openmuse-tailnet.conf >/dev/null &&
        $sudo sysctl -q -p /etc/sysctl.d/60-openmuse-tailnet.conf ||
        warn "Could not apply it. After a reboot, run ./deploy.sh again if the site is down."
      ;;
    *) warn "After a reboot, run ./deploy.sh again if the site does not come back." ;;
  esac
}

# --- Application settings ---------------------------------------------------

configure_app() {
  need WORKSPACE_MODE "Workspace mode (live is required on a server)" live
  [ "$(get_env WORKSPACE_MODE)" = live ] || die "WORKSPACE_MODE must be live on a server: sample mode has no sign-in."

  need AGENT_BACKEND "Agent backend (model or agui)" model
  case "$(get_env AGENT_BACKEND)" in
    model)
      need MODEL "Model, as provider/model-id (openai/…, anthropic/… or google/…)"
      case "$(get_env MODEL)" in
        openai/*) need OPENAI_API_KEY "OpenAI API key" "" secret ;;
        anthropic/*) need ANTHROPIC_API_KEY "Anthropic API key" "" secret ;;
        google/*) need GOOGLE_API_KEY "Google API key" "" secret ;;
        *) warn "MODEL should start with openai/, anthropic/ or google/." ;;
      esac
      ;;
    agui) need AGENT_URL "AG-UI agent URL" ;;
    *) die "AGENT_BACKEND must be model or agui." ;;
  esac

  need CPK_INTELLIGENCE_API_KEY "CopilotKit Intelligence project key (npx copilotkit@latest project select)" "" secret
  need OPENMUSE_ACCESS_KEY "Access key you will type to sign in (24+ characters)" "$(random 32)" secret
  need TOKEN_ENCRYPTION_KEY "Token encryption key (32 bytes, base64)" "$(openssl rand -base64 32)" secret
  need WORKER_TOKEN "Browser worker token (32+ characters)" "$(random 40)" secret

  [ ${#MISSING[@]} -eq 0 ] || return 0
  local key
  key=$(get_env OPENMUSE_ACCESS_KEY); [ ${#key} -ge 24 ] || die "OPENMUSE_ACCESS_KEY must have at least 24 characters."
  key=$(get_env WORKER_TOKEN); [ ${#key} -ge 32 ] || die "WORKER_TOKEN must have at least 32 characters."
}

configure_network
configure_app

if [ ${#MISSING[@]} -gt 0 ]; then
  die "Missing in $(pwd)/.env: ${MISSING[*]}. Run ./deploy.sh in a terminal on the VPS to fill them in."
fi

# --- Deploy ------------------------------------------------------------------

touch .deploy.env
if [ -n "$TAG" ]; then
  sed -i '/^IMAGE_TAG=/d' .deploy.env
  echo "IMAGE_TAG=$TAG" >> .deploy.env
fi
if ! grep -q '^IMAGE_TAG=' .deploy.env; then
  say "✓ Settings saved in $(pwd)/.env"
  echo "No image has been deployed yet: push to main or run Actions → Deploy on GitHub."
  exit 0
fi

FILES=(-f compose.prod.yaml)
if [ "$(get_env NETWORK_MODE)" = tailnet ]; then
  FILES+=(-f compose.tailnet.yaml)
  [ -z "$(get_env BIND_ADDRESS6)" ] || FILES+=(-f compose.tailnet-ipv6.yaml)
fi
compose() { docker compose --env-file .env --env-file .deploy.env "${FILES[@]}" "$@"; }

# Tolerate a failed pull so a rollback can use an image already on the VPS.
compose pull --ignore-pull-failures
compose up -d --remove-orphans --wait --wait-timeout 180
# Keep a week of old images for quick rollbacks.
docker image prune -af --filter until=168h >/dev/null
compose ps

# --- Health check from the VPS itself (the tailnet is not reachable from CI) --

if command -v curl >/dev/null; then
  url=$(get_env PUBLIC_URL)
  if [ "$(get_env NETWORK_MODE)" = local ]; then
    check=("http://127.0.0.1:$(get_env HTTP_PORT)/api/health")
  else
    host=$(get_env DOMAIN)
    port=$(get_env HTTPS_PORT)
    bind=$(get_env BIND_ADDRESS)
    [ "$bind" = 0.0.0.0 ] && bind=127.0.0.1
    check=(--resolve "$host:$port:$bind" "https://$host:$port/api/health")
  fi
  if curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 10 -o /dev/null "${check[@]}"; then
    say "✓ OpenMuse is up at $url"
  else
    die "The stack started but ${check[*]: -1} does not answer. See: docker compose --env-file .env --env-file .deploy.env ${FILES[*]} logs web"
  fi
else
  warn "curl is not installed; skipped the HTTPS check."
fi
