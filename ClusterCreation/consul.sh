#!/usr/bin/env bash
set -euo pipefail

# --- Configuration (EDIT THESE) ---
CONSUL_VERSION="1.19.2"              # pick the version you want
BIND_ADDR="192.168.1.149"              # this machine IP
RETRY_JOIN_IP="192.168.1.53"          # peer to join
DATACENTER="dc1"
BOOTSTRAP_EXPECT="3"

# --- Paths ---
CONSUL_BIN="/usr/local/bin/consul"
CONFIG_DIR="/etc/consul.d"
DATA_DIR="/var/lib/consul"
SERVICE_NAME="consul"

echo "[1/6] Creating consul user (if needed)..."
if ! id consul >/dev/null 2>&1; then
  useradd --system --home /etc/consul.d --shell /usr/sbin/nologin consul
fi

echo "[2/6] Creating directories..."
mkdir -p "$CONFIG_DIR" "$DATA_DIR"
chown -R consul:consul "$CONFIG_DIR" "$DATA_DIR"
chmod 750 "$CONFIG_DIR" "$DATA_DIR"

echo "[3/6] Installing consul binary (if missing)..."
if [[ ! -x "$CONSUL_BIN" ]]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) CONSUL_ARCH="amd64" ;;
    aarch64|arm64) CONSUL_ARCH="arm64" ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
  esac

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  cd "$TMP_DIR"
  apt-get update -y >/dev/null
  apt-get install -y unzip curl >/dev/null

  CONSUL_ZIP="consul_${CONSUL_VERSION}_linux_${CONSUL_ARCH}.zip"
  curl -fsSLO "https://releases.hashicorp.com/consul/${CONSUL_VERSION}/${CONSUL_ZIP}"
  unzip -o "$CONSUL_ZIP"
  install -m 0755 consul "$CONSUL_BIN"
fi

echo "[4/6] Writing configuration to $CONFIG_DIR/consul.hcl ..."
cat > "$CONFIG_DIR/consul.hcl" <<EOF
server = true
datacenter = "${DATACENTER}"
data_dir = "${DATA_DIR}"
bootstrap_expect = ${BOOTSTRAP_EXPECT}
ui = true

bind_addr = "${BIND_ADDR}"
client_addr = "0.0.0.0"

retry_join = ["${RETRY_JOIN_IP}"]

telemetry {
  prometheus_retention_time = "24h"
  disable_hostname = true
}

# Optional but recommended:
# log_level = "INFO"
EOF

chown consul:consul "$CONFIG_DIR/consul.hcl"
chmod 640 "$CONFIG_DIR/consul.hcl"

echo "[5/6] Creating systemd unit /etc/systemd/system/${SERVICE_NAME}.service ..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=HashiCorp Consul Agent
Documentation=https://www.consul.io/docs
Wants=network-online.target
After=network-online.target

[Service]
User=consul
Group=consul
ExecStart=${CONSUL_BIN} agent -config-dir=${CONFIG_DIR}
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo "[6/6] Enabling + starting Consul..."
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo "✅ Consul installed and running as a systemd service!"
echo "   Status:  sudo systemctl status ${SERVICE_NAME} --no-pager"
echo "   Logs:    sudo journalctl -u ${SERVICE_NAME} -f"
echo "   UI:      http://localhost:8500/ui/  (or http://${BIND_ADDR}:8500/ui/)"
