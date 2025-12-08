# Baseado na imagem oficial
FROM hashicorp/consul:1.22

# --- CORREÇÃO SSL (Rede da UA) ---
# Força o uso de HTTP em vez de HTTPS para instalar pacotes
RUN sed -i 's/https/http/g' /etc/apk/repositories

# 1. Instalar APENAS o SSH e o Bash
# (Bash é necessário para teres um terminal decente quando entras)
RUN apk update && apk add --no-cache openssh bash

# 2. Configurar o SSH
# - Define a pass '123456' para o root
# - Gera as chaves de encriptação
# - Permite o login de root
RUN echo "root:123456" | chpasswd && \
    ssh-keygen -A && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    mkdir -p /var/run/sshd

# 3. Preparar a pasta de trabalho (Vazia)
WORKDIR /app

# 4. Copiar o script de arranque
# (Certifica-te que tens o ficheiro start-ssh.sh na mesma pasta)
COPY start-ssh.sh /usr/local/bin/start-ssh.sh
RUN chmod +x /usr/local/bin/start-ssh.sh

# 5. Definir o script como ponto de entrada
ENTRYPOINT ["/usr/local/bin/start-ssh.sh"]

# 6. Comando por defeito do Consul
CMD ["agent", "-dev", "-client", "0.0.0.0"]