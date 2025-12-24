import subprocess
import getpass
import os
import time
import sys

def deploy_remote_agent(host, user, port, ssh_password, loki_ip):
    print(f"\n[INFO] Iniciando configuração do agente em {user}@{host}:{port}...")
    print(f"[INFO] Loki Server alvo: http://{loki_ip}:3100")

    # 1. Criar configuração do Promtail localmente
    print("[STEP 1/3] Gerando configuração do Promtail...")
    promtail_config = f"""
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://{loki_ip}:3100/loki/api/v1/push

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          host: {host}
          __path__: /var/log/*.log
  
  # Adicione aqui outros logs se necessário (ex: Consul, SeaweedFS)
  # - job_name: consul
  #   static_configs:
  #     - targets:
  #         - localhost
  #       labels:
  #         job: consul
  #         __path__: /var/log/consul/*.log
"""
    config_filename = "promtail-config.yaml"
    with open(config_filename, "w") as f:
        f.write(promtail_config)

    # 2. Transferir configuração via SCP
    print("[STEP 2/3] Enviando configuração para o servidor remoto...")
    scp_cmd = [
        "sshpass", "-p", ssh_password,
        "scp", "-P", str(port), "-o", "StrictHostKeyChecking=no", 
        config_filename,
        f"{user}@{host}:/tmp/{config_filename}"
    ]
    
    try:
        subprocess.run(scp_cmd, check=True, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        print(f"[ERRO] Falha ao copiar arquivo via SCP.")
        if e.stderr:
            print(f"Mensagem do SSH:\n{e.stderr.decode()}")
        else:
            print("Sem mensagem de erro específica (provavelmente senha incorreta).")
        
        if os.path.exists(config_filename):
            os.remove(config_filename)
        return

    os.remove(config_filename) # Limpar localmente

    # 3. Instalar e Rodar Promtail remotamente
    print("[STEP 3/3] Instalando e iniciando Promtail no remoto...")
    
    # Script bash que será executado na máquina remota
    # Usamos 'echo password | sudo -S' para passar a senha para o sudo
    # Nota: Dividimos a f-string para evitar erro de aninhamento profundo
    
    remote_script_part1 = f'''
set -e
export SUDO_ASKPASS=/bin/false

# Função auxiliar para rodar sudo com senha
run_sudo() {{
    echo "{ssh_password}" | sudo -S -p '' "$@"
}}

# Verificar se unzip e wget existem
if ! command -v unzip &> /dev/null || ! command -v wget &> /dev/null; then
    echo "[REMOTE] Instalando dependências (unzip, wget)..."
    if [ -x "$(command -v apt-get)" ]; then
        run_sudo apt-get update -qq && run_sudo apt-get install -y -qq unzip wget
    elif [ -x "$(command -v yum)" ]; then
        run_sudo yum install -y -q unzip wget
    fi
fi

# Baixar Promtail se não existir
if [ ! -f "/usr/local/bin/promtail" ]; then
    echo "[REMOTE] Baixando Promtail..."
    wget -q https://github.com/grafana/loki/releases/download/v2.9.4/promtail-linux-amd64.zip
    unzip -o -q promtail-linux-amd64.zip
    run_sudo mv promtail-linux-amd64 /usr/local/bin/promtail
    run_sudo chmod +x /usr/local/bin/promtail
    rm promtail-linux-amd64.zip
else
    echo "[REMOTE] Promtail já instalado."
fi

# Mover config
run_sudo mv /tmp/promtail-config.yaml /etc/promtail-config.yaml

# Criar arquivo de serviço Systemd
echo "[REMOTE] Configurando Systemd Service..."
cat <<EOF > /tmp/promtail.service
[Unit]
Description=Promtail service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail-config.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

run_sudo mv /tmp/promtail.service /etc/systemd/system/promtail.service

# Parar instância anterior (nohup ou service)
run_sudo pkill promtail || true
run_sudo systemctl stop promtail || true

# Recarregar daemon e iniciar serviço
run_sudo systemctl daemon-reload
run_sudo systemctl enable promtail
run_sudo systemctl start promtail

    echo "[REMOTE] Sucesso! Promtail rodando como serviço (systemd)."
    run_sudo systemctl status promtail --no-pager

    # --- NODE EXPORTER ---
    # Baixar Node Exporter se não existir
    if [ ! -f "/usr/local/bin/node_exporter" ]; then
        echo "[REMOTE] Baixando Node Exporter..."
        wget -q https://github.com/prometheus/node_exporter/releases/download/v1.6.1/node_exporter-1.6.1.linux-amd64.tar.gz
        tar xvfz node_exporter-1.6.1.linux-amd64.tar.gz
        run_sudo mv node_exporter-1.6.1.linux-amd64/node_exporter /usr/local/bin/node_exporter
        rm -rf node_exporter-1.6.1.linux-amd64*
    else
        echo "[REMOTE] Node Exporter já instalado."
    fi

    # Criar arquivo de serviço Systemd para Node Exporter
    echo "[REMOTE] Configurando Systemd Service para Node Exporter..."
    cat <<EOF > /tmp/node_exporter.service
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    run_sudo mv /tmp/node_exporter.service /etc/systemd/system/node_exporter.service

    # Parar instância anterior
    run_sudo pkill node_exporter || true
    run_sudo systemctl stop node_exporter || true

    # Recarregar daemon e iniciar serviço
    run_sudo systemctl daemon-reload
    run_sudo systemctl enable node_exporter
    run_sudo systemctl start node_exporter

    echo "[REMOTE] Sucesso! Node Exporter rodando como serviço (systemd)."
    run_sudo systemctl status node_exporter --no-pager
'''

    remote_script_part2 = '''
# 4. Registrar no Consul (se existir)
if [ -d "/etc/consul.d" ]; then
    echo "[REMOTE] Detectado Consul. Registrando serviços..."
    
    # Promtail
    cat <<EOF > /tmp/promtail-consul.json
{
  "service": {
    "name": "promtail",
    "tags": ["logs", "monitoring"],
    "port": 9080,
    "checks": [
      {
        "id": "promtail-check",
        "name": "Promtail HTTP Check",
        "http": "http://localhost:9080/ready",
        "interval": "10s",
        "timeout": "1s"
      }
    ]
  }
}
EOF
    run_sudo mv /tmp/promtail-consul.json /etc/consul.d/promtail.json

    # Node Exporter
    cat <<EOF > /tmp/node-exporter-consul.json
{
  "service": {
    "name": "node-exporter",
    "tags": ["metrics", "monitoring"],
    "port": 9100,
    "checks": [
      {
        "id": "node-exporter-check",
        "name": "Node Exporter HTTP Check",
        "http": "http://localhost:9100/metrics",
        "interval": "10s",
        "timeout": "1s"
      }
    ]
  }
}
EOF
    run_sudo mv /tmp/node-exporter-consul.json /etc/consul.d/node-exporter.json
    
    # Recarregar Consul para ler a nova config
    echo "[REMOTE] Recarregando Consul..."
    run_sudo consul reload || echo "[AVISO] Falha ao recarregar Consul. Tente 'consul reload' manualmente."
else
    echo "[REMOTE] Consul não detectado em /etc/consul.d. Pulando registro."
fi
'''
    
    remote_script = remote_script_part1 + remote_script_part2
    
    ssh_cmd = [
        "sshpass", "-p", ssh_password,
        "ssh", "-p", str(port), "-o", "StrictHostKeyChecking=no", f"{user}@{host}", "bash -s"
    ]
    
    try:
        # Nota: input deve ser string se text=True, ou bytes se text=False.
        # Como estamos passando remote_script (string), não precisamos de .encode() se text=True.
        proc = subprocess.run(ssh_cmd, input=remote_script, check=True, capture_output=True, text=True)
        print(proc.stdout)
        print("\n[SUCESSO] Agente implantado com sucesso!")
    except subprocess.CalledProcessError as e:
        print(f"\n[ERRO] Falha na execução remota via SSH.")
        print(f"Saída de erro remota:\n{e.stderr}")

if __name__ == "__main__":
    print("=== Deploy do Agente de Logs (Promtail) ===")
    host = input("IP da Máquina Alvo (ex: 192.168.1.72): ")
    user = input("Usuário SSH (ex: root): ")
    port = input("Porta SSH [22]: ") or "22"
    ssh_password = getpass.getpass(f"Senha SSH para {user}@{host}: ")
    
    default_loki = "192.168.1.68"
    loki_ip = input(f"IP do seu PC (Loki Server) [{default_loki}]: ") or default_loki
    
    deploy_remote_agent(host, user, port, ssh_password, loki_ip)