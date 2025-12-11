#!/bin/sh

set -e

# 1. Iniciar o SSH em background
/usr/sbin/sshd

echo "🔓 [SSH] Servidor SSH iniciado na porta 22"
echo "🔑 Login: root / 123456"

# -------------------------------
# 2. CONFIGURAR PROMTAIL
# -------------------------------
# Usa a variável de ambiente LOKI_IP (definida no Dockerfile ou docker-compose)
LOKI_ADDR="${LOKI_IP:-172.20.10.8}"

mkdir -p /etc/promtail
mkdir -p /var/log/chaos

cat >/etc/promtail/promtail-config.yaml <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0
positions:
  filename: /tmp/positions.yaml
clients:
  - url: http://${LOKI_ADDR}:3100/loki/api/v1/push
scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          __path__: /var/log/*log
  - job_name: docker
    static_configs:
      - targets:
          - localhost
        labels:
          job: dockerlogs
          __path__: /var/lib/docker/containers/*/*.log
EOF

echo "📝 [Promtail] Configuração gerada para Loki em ${LOKI_ADDR}:3100"

# -------------------------------
# 3. ARRANCAR chaosd / node_exporter / promtail
# -------------------------------

# chaosd (já instalado no Dockerfile em /usr/local/bin/chaosd)
if command -v chaosd >/dev/null 2>&1; then
  echo "⚡ [Chaosd] A iniciar chaosd na porta 31767..."
  chaosd server --port 31767 --address 0.0.0.0 \
    > /var/log/chaos/chaosd.log 2>&1 &
else
  echo "⚠️ [Chaosd] Binário chaosd não encontrado (ver Dockerfile)"
fi

# node_exporter (já instalado no Dockerfile em /usr/local/bin/node_exporter)
if command -v node_exporter >/dev/null 2>&1; then
  echo "📊 [Metrics] A iniciar node_exporter na porta 9100..."
  node_exporter --web.listen-address=":9100" \
    > /var/log/chaos/node_exporter.log 2>&1 &
else
  echo "⚠️ [Metrics] Binário node_exporter não encontrado (ver Dockerfile)"
fi

# promtail (já instalado no Dockerfile em /usr/local/bin/promtail)
if command -v promtail >/dev/null 2>&1; then
  echo "📜 [Logs] A iniciar promtail..."
  promtail -config.file=/etc/promtail/promtail-config.yaml \
    > /var/log/chaos/promtail.log 2>&1 &
else
  echo "⚠️ [Logs] Binário promtail não encontrado (ver Dockerfile)"
fi

# -------------------------------
# 4. Iniciar a aplicação Python em background
#    (espera que o Consul arranque e tenha líder)
# -------------------------------
(
    echo "⏳ [App] À espera que o Consul inicie..."

    # Loop até o Consul local responder E haver um líder
    while true; do
        # Check 1: Is local agent API up?
        if curl -s http://127.0.0.1:8500/v1/agent/self > /dev/null; then
            # Check 2: Is there a leader?
            LEADER=$(curl -s http://127.0.0.1:8500/v1/status/leader)
            if [ -n "$LEADER" ] && [ "$LEADER" != '""' ]; then
                echo "✅ [App] Consul pronto e Líder encontrado: $LEADER"
                break
            fi
        fi
        sleep 2
    done

    echo "🚀 [App] A iniciar main.py..."
    python main.py 2>&1 &

    echo " Filesystem"
    python filesystem.py 2>&1 &
) &

# -------------------------------
# 5. Passar o controlo para o Consul (entrypoint original)
# -------------------------------
exec /usr/local/bin/docker-entrypoint.sh "$@"
