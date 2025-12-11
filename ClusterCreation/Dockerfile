# Baseado na imagem oficial
FROM hashicorp/consul:1.22
 
# --- 1. CORREÇÃO DE REPOSITÓRIOS ---
RUN sed -i 's/https/http/g' /etc/apk/repositories
 
# --- 2. INSTALAÇÃO DE PACOTES ---
# Adicionamos 'tar' para descompactar o seaweed
RUN apk update && apk add --no-cache openssh python3 py3-requests py3-pip bash curl nano tar
 
# Permitir instalação de pacotes Python globais
RUN rm /usr/lib/python*/EXTERNALLY-MANAGED || true
 
# --- 3. INSTALAÇÃO DO SEAWEEDFS (INTEGRAÇÃO GRUPO 3) ---
ENV SEAWEED_VERSION=3.59
# Descarregar o binário, extrair para /usr/local/bin e criar pastas de dados
RUN curl -L -k https://github.com/seaweedfs/seaweedfs/releases/download/${SEAWEED_VERSION}/linux_amd64.tar.gz -o seaweed.tar.gz && \
    tar -C /usr/local/bin -xzvf seaweed.tar.gz && \
    rm seaweed.tar.gz && \
    mkdir -p /data/seaweed_master /data/seaweed_volume /data/seaweed_filer
 
# --- 4. CONFIGURAÇÃO SSH ---
RUN echo "root:123456" | chpasswd && \
    ssh-keygen -A && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    mkdir -p /var/run/sshd
 
# --- 5. PREPARAR APLICAÇÃO ---
WORKDIR /app
RUN echo "cd /app" >> /root/.profile
 
COPY cluster_helper.py /app/
COPY main.py /app/
COPY filesystem.py /app/
 
# --- 6. CONFIGURAÇÃO DE ARRANQUE ---
COPY start-ssh.sh /usr/local/bin/start-ssh.sh
RUN sed -i 's/\r$//' /usr/local/bin/start-ssh.sh
RUN chmod +x /usr/local/bin/start-ssh.sh
 
ENTRYPOINT ["/usr/local/bin/start-ssh.sh"]
CMD ["agent", "-dev", "-client", "0.0.0.0"]


