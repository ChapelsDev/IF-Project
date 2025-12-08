FROM hashicorp/consul:1.22

# Instalar OpenSSH, iproute2 (para tc) e sudo
RUN apk add --no-cache openssh iproute2 sudo

# Configurar SSH
# Define a senha de root para '123456'
# Gera as chaves de host
# Permite login de root
RUN echo "root:123456" | chpasswd && \
    ssh-keygen -A && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    mkdir -p /run/sshd

# Copiar o script de entrada personalizado
COPY entrypoint.sh /usr/local/bin/custom-entrypoint.sh
RUN chmod +x /usr/local/bin/custom-entrypoint.sh

# Definir o novo entrypoint
ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]

# O CMD padrão pode ser sobrescrito pelo docker-compose
CMD ["agent", "-dev", "-client", "0.0.0.0"]
