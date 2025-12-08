#!/bin/sh
set -e

# Iniciar o SSH em background
/usr/sbin/sshd

# Executar o comando original (Consul)
# O script original de entrada da imagem consul é docker-entrypoint.sh
exec docker-entrypoint.sh "$@"