#!/usr/bin/env bash
# install-ss-libev.sh
# Idempotent installer for Shadowsocks-libev server with systemd unit and wrapper.
# Usage:
#   sudo PORT=30001 PASS='MyStrongPass' METHOD=aes-256-gcm ./install-ss-libev.sh


set -euo pipefail

# ====== Config (env overrides allowed) ======
PORT="${PORT:-8388}"
PASS="${PASS:-655524}"
METHOD="${METHOD:-aes-256-gcm}"
MODE="${MODE:-tcp_and_udp}"
TIMEOUT="${TIMEOUT:-60}"

CONF_DIR="/etc/shadowsocks-libev"
CONF_FILE="$CONF_DIR/config.json"
WRAP="/usr/local/bin/shadowsocks-libev-wrapper"
UNIT="/etc/systemd/system/shadowsocks-libev.service"

# ====== Helpers ======
log() { printf "\n\033[1;36m[INFO]\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die(){ printf "\033[1;31m[ERR]\033[0m %s\n" "$*"; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "Run as root (use sudo)."; }

backup_if_exists() {
  local f="$1"
  if [ -f "$f" ]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
    ok "Backup created: ${f}.bak.*"
  fi
}

# ====== Start ======
require_root
log "Starting Shadowsocks-libev installation"

# 1) Packages
log "Installing packages (shadowsocks-libev)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y shadowsocks-libev >/dev/null
ok "Packages installed"

# 2) Config
log "Writing config to ${CONF_FILE}"
install -d -m 0755 "$CONF_DIR"
backup_if_exists "$CONF_FILE"
cat >"$CONF_FILE" <<EOF
{
   "server": ["0.0.0.0"],
  "mode": "$MODE",
  "server_port": $PORT,
  "local_port": 1080,
  "password": "$PASS",
  "timeout": $TIMEOUT,
  "fast_open": true,
  "reuse_port": true,
  "no_delay": true,
  "method": "$METHOD"
}
EOF
chmod 600 "$CONF_FILE"
ok "Config created"

# 3) Wrapper
log "Creating wrapper ${WRAP}"
backup_if_exists "$WRAP"
cat >"$WRAP" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/ss-server -c /etc/shadowsocks-libev/config.json
EOF
chmod +x "$WRAP"
ok "Wrapper ready"

# 4) systemd unit
log "Installing systemd unit ${UNIT}"
backup_if_exists "$UNIT"
cat >"$UNIT" <<'EOF'
[Unit]
Description=Shadowsocks-Libev Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/shadowsocks-libev-wrapper
Restart=on-failure
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF
ok "Unit written"

# 5) Enable & start
log "Reloading systemd and starting service"
systemctl daemon-reload
systemctl enable --now shadowsocks-libev.service >/dev/null
sleep 1
systemctl is-active --quiet shadowsocks-libev.service && ok "Service started" || die "Service failed to start"

# 6) (Optional) UFW rules if UFW installed
if command -v ufw >/dev/null 2>&1; then
  log "Configuring UFW rules (if not present)"
  ufw status | grep -q "${PORT}/tcp" || ufw allow "${PORT}/tcp" >/dev/null || true
  ufw status | grep -q "${PORT}/udp" || ufw allow "${PORT}/udp" >/dev/null || true
  ok "UFW rules ensured for ${PORT}/tcp and ${PORT}/udp"
else
  warn "UFW not installed — skipping firewall rules"
fi

# 7) Optional TCP tuning
if sysctl -n net.ipv4.tcp_congestion_control >/dev/null 2>&1; then
  log "Applying optional TCP tuning (bbr/fq)"
  sysctl -w net.core.default_qdisc=fq >/dev/null || true
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || true
  ok "TCP tuning applied (best effort)"
fi

sudo ufw allow 8388/udp
sudo ufw allow 8388/tcp

iptables -I INPUT -p tcp --dport 8388 -j ACCEPT
iptables -I INPUT -p udp --dport 8388 -j ACCEPT

sudo systemctl restart shadowsocks-libev
sudo systemctl status shadowsocks-libev --no-pager
sudo ss -ltnup | grep 8388
sudo ss -lunup | grep 8388

# safety-fix: если в конфиге массив адресов — заменить на строку 0.0.0.0
#sed -i 's/"server"[[:space:]]*:[[:space:]]*\[[^]]*\]/"server": "0.0.0.0"/' "$CONF_FILE"

# 8) Final status


log "Final checks"
echo "----- systemctl status -----"
systemctl --no-pager --full status shadowsocks-libev.service | sed -n '1,40p' || true

echo "----- listening sockets (ss-server) -----"
ss -ltnup 2>/dev/null | grep -E "(:${PORT}\s)|ss-server" || true
ss -lunup 2>/dev/null | grep -E "(:${PORT}\s)|ss-server" || true

echo "----- recent logs -----"
journalctl -u shadowsocks-libev.service -n 30 --no-pager || true

ok "Done. Port=${PORT}, Method=${METHOD}, Mode=${MODE}"
echo "Tip: change password via:  sed -i 's/\"password\": \".*\"/\"password\": \"NEWPASS\"/' ${CONF_FILE} && systemctl restart shadowsocks-libev"



















