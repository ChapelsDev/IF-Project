#!/bin/sh

# 1. Iniciar o SSH em background
/usr/sbin/sshd

echo "🔓 [SSH] Servidor SSH iniciado na porta 22"
echo "🔑 Login: root / 123456"

# 2. Iniciar a aplicação Python em background
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
    
    echo "📂 [App] A iniciar filesystem.py..."
    python filesystem.py 2>&1 &
    
) &

# 3. Passar o controlo para o Consul
exec /usr/local/bin/docker-entrypoint.sh "$@"