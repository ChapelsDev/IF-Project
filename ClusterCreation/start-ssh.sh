#!/bin/sh

# 1. Iniciar o SSH em background
/usr/sbin/sshd

echo "🔓 [SSH] Servidor SSH iniciado na porta 22"
echo "🔑 Login: root / 123456"

# 2. Passar o controlo para o Consul
# "$@" representa todos os argumentos que passamos no docker-compose (agent -server...)
exec /usr/local/bin/docker-entrypoint.sh "$@"