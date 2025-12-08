# Baseado na imagem oficial
FROM hashicorp/consul:1.22

# --- 1. CORREÇÃO DE REPOSITÓRIOS ---
RUN sed -i 's/https/http/g' /etc/apk/repositories

# --- 2. INSTALAÇÃO DE PACOTES ---
RUN apk update && apk add --no-cache openssh python3 py3-requests py3-pip bash curl nano

# Permitir instalação de pacotes Python globais
RUN rm /usr/lib/python*/EXTERNALLY-MANAGED || true

# --- 3. CONFIGURAÇÃO SSH ---
RUN echo "root:123456" | chpasswd && \
    ssh-keygen -A && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    mkdir -p /var/run/sshd

# --- 4. PREPARAR APLICAÇÃO ---
WORKDIR /app

RUN echo "cd /app" >> /root/.profile

# >>> MUDANÇA AQUI: Copiar apenas ficheiros específicos <<<
COPY cluster_helper.py /app/
COPY main.py /app/

# --- 5. CONFIGURAÇÃO DE ARRANQUE ---
# Precisamos copiar o script de arranque explicitamente para o sítio certo
COPY start-ssh.sh /usr/local/bin/start-ssh.sh
RUN chmod +x /usr/local/bin/start-ssh.sh

# Definir o script como ponto de entrada
ENTRYPOINT ["/usr/local/bin/start-ssh.sh"]

# Comando por defeito do Consul
CMD ["agent", "-dev", "-client", "0.0.0.0"]