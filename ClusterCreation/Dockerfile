# Baseado na imagem oficial
FROM hashicorp/consul:1.22

# --- 1. CORREÇÃO DE REPOSITÓRIOS ---
RUN sed -i 's/https/http/g' /etc/apk/repositories

# --- 2. INSTALAÇÃO DE PACOTES ---
# Adicionamos 'tar' e 'unzip' (promtail)  # >>> NEW: unzip
RUN apk update && apk add --no-cache \
    openssh python3 py3-requests py3-pip bash curl nano tar unzip

# Permitir instalação de pacotes Python globais
RUN rm /usr/lib/python*/EXTERNALLY-MANAGED || true

# --- 3. INSTALAÇÃO DO SEAWEEDFS (INTEGRAÇÃO GRUPO 3) ---
ENV SEAWEED_VERSION=3.59
RUN curl -L -k https://github.com/seaweedfs/seaweedfs/releases/download/${SEAWEED_VERSION}/linux_amd64.tar.gz -o seaweed.tar.gz && \
    tar -C /usr/local/bin -xzvf seaweed.tar.gz && \
    rm seaweed.tar.gz && \
    mkdir -p /data/seaweed_master /data/seaweed_volume /data/seaweed_filer

# --- 3b. INSTALAR CHAOSD / NODE_EXPORTER / PROMTAIL ---  # >>> NEW
ENV CHAOSD_VERSION=v1.4.0
ENV NODE_EXPORTER_VERSION=1.8.2
ENV PROMTAIL_VERSION=2.9.4

# chaosd
RUN curl -fsSL -k https://mirrors.chaos-mesh.org/chaosd-${CHAOSD_VERSION}-linux-amd64.tar.gz -o chaosd.tar.gz && \
    tar -xzvf chaosd.tar.gz && \
    mv chaosd-${CHAOSD_VERSION}-linux-amd64/chaosd /usr/local/bin/chaosd && \
    rm -rf chaosd.tar.gz chaosd-${CHAOSD_VERSION}-linux-amd64

# node_exporter
RUN curl -fsSL -k https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz -o node_exporter.tar.gz && \
    tar -xzvf node_exporter.tar.gz && \
    mv node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/node_exporter && \
    rm -rf node_exporter.tar.gz node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64

# promtail
RUN curl -L -k https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip -o promtail.zip && \
    unzip promtail.zip && \
    mv promtail-linux-amd64 /usr/local/bin/promtail && \
    chmod +x /usr/local/bin/promtail && \
    rm promtail.zip

# Diretórios de logs (opcional)
RUN mkdir -p /var/log/chaos /etc/promtail

# Loki IP por defeito (podes mudar via docker-compose env)  # >>> NEW
ENV LOKI_IP=172.20.10.8

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
