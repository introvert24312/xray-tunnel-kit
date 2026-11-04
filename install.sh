#!/usr/bin/env bash
set -Eeuo pipefail

# Xray over Cloudflare Tunnel: fixed named tunnel or temporary Quick Tunnel.
# Usage examples are documented in README.md.

TUNNEL_MODE="${TUNNEL_MODE:-}"
ORIGIN_PORT="${ORIGIN_PORT:-10126}"
DOMAIN="${DOMAIN:-}"
UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)}"
BASE_DIR="/etc/xray-tunnel-kit"
XRAY_BIN="/usr/local/bin/xray"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"

say() { printf '\n[%s] %s\n' "$1" "$2"; }
die() { say ERROR "$1" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die 'Run as root (for example: sudo -E ./install.sh).'
[[ "$TUNNEL_MODE" == fixed || "$TUNNEL_MODE" == quick ]] || die 'Set TUNNEL_MODE=fixed or TUNNEL_MODE=quick.'
[[ "$ORIGIN_PORT" =~ ^[0-9]+$ ]] && (( ORIGIN_PORT >= 1024 && ORIGIN_PORT <= 65500 )) || die 'ORIGIN_PORT must be between 1024 and 65500.'
(( ORIGIN_PORT + 2 <= 65535 )) || die 'ORIGIN_PORT is too high; two following ports are reserved for loopback Xray listeners.'
[[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'UUID must be a UUID string.'
if [[ "$TUNNEL_MODE" == fixed ]]; then
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die 'For fixed mode, set DOMAIN to the public hostname routed in Cloudflare.'
fi

command -v apt-get >/dev/null || die 'This installer currently supports Debian/Ubuntu (apt).'
command -v systemctl >/dev/null || die 'systemd is required.'

# Reserve the chosen port for local Caddy. Never flush or change firewall rules.
if ss -H -lnt "sport = :${ORIGIN_PORT}" 2>/dev/null | grep -q .; then
  die "Port ${ORIGIN_PORT} is already listening. Choose another ORIGIN_PORT or stop the existing service."
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) XRAY_ARCH=64; CF_ARCH=amd64 ;;
  aarch64|arm64) XRAY_ARCH=arm64-v8a; CF_ARCH=arm64 ;;
  *) die "Unsupported CPU architecture: $ARCH (supported: x86_64, aarch64)." ;;
esac

say INFO 'Installing required packages.'
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl unzip gnupg debian-keyring debian-archive-keyring apt-transport-https

if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -y
  apt-get install -y caddy
fi

getent passwd xray >/dev/null 2>&1 || adduser --system --group --no-create-home --shell /usr/sbin/nologin xray
install -d -o root -g xray -m 0750 "$BASE_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

say INFO 'Downloading Xray and cloudflared.'
curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip" -o "$TMP_DIR/xray.zip"
unzip -oq "$TMP_DIR/xray.zip" xray -d "$TMP_DIR/xray"
install -m 0755 "$TMP_DIR/xray/xray" "$XRAY_BIN"
curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" -o "$CLOUDFLARED_BIN"
chmod 0755 "$CLOUDFLARED_BIN"

VLESS_PORT=$((ORIGIN_PORT + 1))
VMESS_PORT=$((ORIGIN_PORT + 2))
cat > "$BASE_DIR/config.json" <<EOF_CONFIG
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vless-argo" } }
    },
    {
      "listen": "127.0.0.1",
      "port": ${VMESS_PORT},
      "protocol": "vmess",
      "settings": { "clients": [{ "id": "${UUID}", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vmess-argo" } }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF_CONFIG
chown root:xray "$BASE_DIR/config.json"
chmod 0640 "$BASE_DIR/config.json"

cat > /etc/caddy/Caddyfile <<EOF_CADDY
{
  auto_https off
}
127.0.0.1:${ORIGIN_PORT} {
  @vless path /vless-argo /vless-argo/*
  handle @vless {
    reverse_proxy 127.0.0.1:${VLESS_PORT}
  }
  @vmess path /vmess-argo /vmess-argo/*
  handle @vmess {
    reverse_proxy 127.0.0.1:${VMESS_PORT}
  }
  handle {
    respond "Not found" 404
  }
}
EOF_CADDY

cat > /etc/systemd/system/xray-tunnel-kit-xray.service <<EOF_XRAY
[Unit]
Description=Xray WS services for Cloudflare Tunnel
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=xray
Group=xray
ExecStart=${XRAY_BIN} run -c ${BASE_DIR}/config.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF_XRAY

# Disable only this kit's own quick-tunnel unit if switching to fixed mode.
if [[ "$TUNNEL_MODE" == quick ]]; then
  cat > /etc/systemd/system/xray-tunnel-kit-cloudflared.service <<EOF_QUICK
[Unit]
Description=Cloudflare Quick Tunnel for Xray Tunnel Kit
After=network-online.target caddy.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --url http://127.0.0.1:${ORIGIN_PORT} --no-autoupdate
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF_QUICK
  systemctl disable --now xray-tunnel-kit-cloudflared.service >/dev/null 2>&1 || true
else
  systemctl disable --now xray-tunnel-kit-cloudflared.service >/dev/null 2>&1 || true
fi

cat > "$BASE_DIR/settings" <<EOF_SETTINGS
TUNNEL_MODE=${TUNNEL_MODE}
ORIGIN_PORT=${ORIGIN_PORT}
DOMAIN=${DOMAIN}
UUID=${UUID}
VLESS_PATH=/vless-argo
VMESS_PATH=/vmess-argo
EOF_SETTINGS
chmod 0600 "$BASE_DIR/settings"

# Validate before enabling/restarting services.
"$XRAY_BIN" run -test -c "$BASE_DIR/config.json"
/usr/bin/caddy validate --config /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable --now xray-tunnel-kit-xray.service caddy.service
systemctl restart caddy.service

if [[ "$TUNNEL_MODE" == quick ]]; then
  systemctl enable --now xray-tunnel-kit-cloudflared.service
  say INFO 'Waiting for Quick Tunnel hostname.'
  HOST=''
  for _ in $(seq 1 30); do
    HOST="$(journalctl -u xray-tunnel-kit-cloudflared.service --since '-2 minutes' --no-pager -o cat 2>/dev/null | grep -Eo '[a-z0-9-]+\.trycloudflare\.com' | tail -n1 || true)"
    [[ -n "$HOST" ]] && break
    sleep 2
  done
  if [[ -n "$HOST" ]]; then
    printf 'DOMAIN=%s\n' "$HOST" >> "$BASE_DIR/settings"
  else
    say WARN 'Tunnel hostname not found yet. Check it later with: journalctl -u xray-tunnel-kit-cloudflared -n 50 --no-pager'
  fi
else
  HOST="$DOMAIN"
fi

cat > /usr/local/bin/xray-tunnel-kit-links <<'EOF_LINKS'
#!/usr/bin/env bash
set -euo pipefail
. /etc/xray-tunnel-kit/settings
HOST="${1:-${DOMAIN:-}}"
[[ -n "$HOST" ]] || { echo 'Usage: xray-tunnel-kit-links HOSTNAME' >&2; exit 1; }
cat <<EOF_OUT
VLESS WS+TLS:
vless://${UUID}@${HOST}:443?encryption=none&security=tls&sni=${HOST}&type=ws&host=${HOST}&path=%2Fvless-argo#xray-tunnel-kit-vless

VMess WS+TLS:
EOF_OUT
VMESS_JSON="{\"v\":\"2\",\"ps\":\"xray-tunnel-kit-vmess\",\"add\":\"${HOST}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${HOST}\",\"path\":\"/vmess-argo\",\"tls\":\"tls\",\"sni\":\"${HOST}\"}"
printf 'vmess://%s\n' "$(printf '%s' "$VMESS_JSON" | base64 -w0)"
EOF_LINKS
chmod 0755 /usr/local/bin/xray-tunnel-kit-links

say DONE 'Xray and the local WebSocket router are installed.'
printf 'Origin port: %s (loopback only)\n' "$ORIGIN_PORT"
printf 'Xray VLESS listener: 127.0.0.1:%s\nXray VMess listener: 127.0.0.1:%s\n' "$VLESS_PORT" "$VMESS_PORT"
if [[ "$TUNNEL_MODE" == fixed ]]; then
  printf 'Cloudflare Dashboard route service must be: http://127.0.0.1:%s\n' "$ORIGIN_PORT"
  printf 'Public hostname: %s\n' "$DOMAIN"
  printf 'Generate links: xray-tunnel-kit-links\n'
else
  printf 'Quick Tunnel hostname: %s\n' "${HOST:-not detected yet}"
  printf 'Check logs: journalctl -u xray-tunnel-kit-cloudflared -n 50 --no-pager\n'
  printf 'Generate links: xray-tunnel-kit-links HOSTNAME.trycloudflare.com\n'
fi
