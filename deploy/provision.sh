#!/usr/bin/env bash
# Provision one RoachChat region on a fresh Debian 12 VM.
#
# Idempotent: safe to re-run (updates code + config, rebuilds, restarts).
# Everything is built natively on the VM (amd64) — no cross-arch emulation,
# which is where the mix "already compiled" bug lives.
#
# Required env (see deploy/<region>.env produced by deploy/mesh.sh):
#   REGION_INDEX  WG_IP  WG_PRIVKEY  PUBLIC_HOST  PEER_REGIONS  WG_PEERS
# WG_PEERS is newline-separated "PUBKEY ENDPOINT:51820 WG_IP/32" lines.
set -euo pipefail

echo "== [$PUBLIC_HOST region $REGION_INDEX] installing packages =="
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  wireguard-tools git ca-certificates curl >/dev/null

if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh >/dev/null 2>&1
fi
sudo systemctl enable --now docker >/dev/null 2>&1 || true

echo "== configuring WireGuard ($WG_IP) =="
sudo mkdir -p /etc/wireguard
{
  echo "[Interface]"
  echo "Address = ${WG_IP}/24"
  echo "ListenPort = 51820"
  echo "PrivateKey = ${WG_PRIVKEY}"
  printf '%s\n' "$WG_PEERS" | while read -r pub endpoint wgip; do
    [ -z "$pub" ] && continue
    echo
    echo "[Peer]"
    echo "PublicKey = ${pub}"
    echo "Endpoint = ${endpoint}"
    echo "AllowedIPs = ${wgip}"
    echo "PersistentKeepalive = 25"
  done
} | sudo tee /etc/wireguard/wg0.conf >/dev/null
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
sudo wg-quick down wg0 >/dev/null 2>&1 || true
sudo wg-quick up wg0

echo "== fetching RoachChat =="
if [ ! -d "$HOME/RoachChat/.git" ]; then
  git clone --depth 1 https://github.com/Lore-Hex/RoachChat.git "$HOME/RoachChat"
else
  git -C "$HOME/RoachChat" fetch --depth 1 origin main && git -C "$HOME/RoachChat" reset --hard origin/main
fi
cd "$HOME/RoachChat"

echo "== writing region config =="
sed "s|PUBLIC_HOST_PLACEHOLDER|${PUBLIC_HOST}|" deploy/Caddyfile.tmpl > deploy/Caddyfile
cat > deploy/.env <<EOF
PUBLIC_HOST=${PUBLIC_HOST}
COMETCHAT_API_KEY=${COMETCHAT_API_KEY:-roach-admin-key-change-me}
REGION_INDEX=${REGION_INDEX}
WG_IP=${WG_IP}
PEER_REGIONS=${PEER_REGIONS}
EOF

echo "== building + starting (native amd64) =="
sudo docker compose --env-file deploy/.env -f deploy/docker-compose.prod.yml up -d --build

echo "== provisioned region $REGION_INDEX ($PUBLIC_HOST) =="
