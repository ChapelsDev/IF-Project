#!/bin/bash
set -e

# Instalação do Consul bare-metal
CONSUL_VERSION="1.16.2"

# 1. Baixar e instalar Consul
wget https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip
unzip consul_${CONSUL_VERSION}_linux_amd64.zip
sudo mv consul /usr/local/bin/

# 2. Criar usuário e diretórios
sudo useradd --system --home /etc/consul.d --shell /bin/false consul || true
sudo mkdir -p /etc/consul.d
sudo mkdir -p /opt/consul
sudo chown -R consul:consul /etc/consul.d /opt/consul

# 3. Gerar configuração básica
cat <<EOF | sudo tee /etc/consul.d/consul.hcl
# Configuração básica do Consul
server = true
datacenter = "dc1"
data_dir = "/opt/consul"
bootstrap_expect = 2
ui = true
bind_addr = "0.0.0.0"
client_addr = "0.0.0.0"
retry_join = ["172.20.10.8"]
EOF
sudo chown consul:consul /etc/consul.d/consul.hcl

# 4. Criar serviço systemd
cat <<EOF | sudo tee /etc/systemd/system/consul.service
[Unit]
Description=Consul Agent
Requires=network-online.target
After=network-online.target

[Service]
User=consul
Group=consul
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 5. Ativar e iniciar o Consul
sudo systemctl daemon-reload
sudo systemctl enable consul
sudo systemctl start consul

echo "Consul instalado e rodando como serviço!"
echo "Acesse a UI em http://<ip-do-servidor>:8500/ui/"
