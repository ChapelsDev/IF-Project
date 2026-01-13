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

# Detectar Arquitetura
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    display_arch="amd64"
elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    display_arch="arm64"
else
    echo "[ERRO] Arquitetura $ARCH não suportada por este script."
    exit 1
fi

echo "[REMOTE] Arquitetura detectada: $ARCH ($display_arch)"

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
    echo "[REMOTE] Baixando Promtail ($display_arch)..."
    wget -q "https://github.com/grafana/loki/releases/download/v2.9.4/promtail-linux-$display_arch.zip"
    unzip -o -q "promtail-linux-$display_arch.zip"
    run_sudo mv "promtail-linux-$display_arch" /usr/local/bin/promtail
    run_sudo chmod +x /usr/local/bin/promtail
    rm "promtail-linux-$display_arch.zip"
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
        echo "[REMOTE] Baixando Node Exporter ($display_arch)..."
        wget -q "https://github.com/prometheus/node_exporter/releases/download/v1.6.1/node_exporter-1.6.1.linux-$display_arch.tar.gz"
        tar xvfz "node_exporter-1.6.1.linux-$display_arch.tar.gz"
        run_sudo mv "node_exporter-1.6.1.linux-$display_arch/node_exporter" /usr/local/bin/node_exporter
        rm -rf "node_exporter-1.6.1.linux-$display_arch"*
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
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9101
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    run_sudo mv /tmp/node_exporter.service /etc/systemd/system/node_exporter.service

    # Parar instância anterior
    echo "[REMOTE] Parando instância anterior do NOSSO serviço (se houver)..."
    run_sudo systemctl stop node_exporter || true
    
    # Forçar liberação da porta 9101 com múltiplas tentativas
    echo "[REMOTE] Verificando e liberando porta 9101..."
    for i in $(seq 1 5); do
        # Verifica se alguém ouve na 9101 (ss ou netstat)
        if ! ( run_sudo ss -lptn | grep -q ":9101" ) && ! ( run_sudo netstat -lptn 2>/dev/null | grep -q ":9101" ); then
            echo "[REMOTE] Porta 9101 confirmada como livre."
            break
        fi

        echo "[REMOTE] Porta 9101 ainda em uso (Tentativa $i)..."
        
        # Tenta fuser (se existir)
        if command -v fuser &> /dev/null; then
             run_sudo fuser -k -9 9101/tcp || true
        fi

        # Tenta matar via PID extraído do SS
        # Formato típico: users:(("node_exporter",pid=123,fd=3))
        PID=$(run_sudo ss -lptn 'sport = :9101' | grep -o "pid=[0-9]*" | cut -d= -f2 | head -n1)
        
        if [ ! -z "$PID" ]; then
             echo "[REMOTE] Matando PID $PID..."
             run_sudo kill -9 "$PID" || true
        else
             # Fallback agressivo
             run_sudo pkill -9 -f "node_exporter.*9101" || true
        fi
        
        sleep 2
    done

    # Recarregar daemon e iniciar serviço
    run_sudo systemctl daemon-reload
    run_sudo systemctl enable node_exporter
    run_sudo systemctl start node_exporter

    echo "[REMOTE] Sucesso! Node Exporter rodando como serviço (systemd)."
    run_sudo systemctl status node_exporter --no-pager || \
    (echo "[ERROR] Status falhou. Logs recentes:" && run_sudo journalctl -u node_exporter --no-pager -n 20)

    # --- NATS EXPORTER ---
    if [ ! -f "/usr/local/bin/prometheus-nats-exporter" ]; then
        echo "[REMOTE] Baixando NATS Exporter ($display_arch)..."
        NATS_VER="v0.18.0"
        # Ajuste de arquitetura para NATS (x86_64 vs amd64)
        if [ "$display_arch" = "amd64" ]; then
            nats_arch="x86_64"
        else
            nats_arch="$display_arch"
        fi
        
        wget -q "https://github.com/nats-io/prometheus-nats-exporter/releases/download/$NATS_VER/prometheus-nats-exporter-$NATS_VER-linux-$nats_arch.tar.gz"
        tar xvfz "prometheus-nats-exporter-$NATS_VER-linux-$nats_arch.tar.gz"
        
        # Mover binário (estrutura flat do tar)
        run_sudo mv "prometheus-nats-exporter" /usr/local/bin/prometheus-nats-exporter
        
        rm -f "prometheus-nats-exporter-$NATS_VER-linux-$nats_arch.tar.gz"
        rm -f "LICENSE" "README.md"
    else
        echo "[REMOTE] NATS Exporter já instalado."
    fi

    echo "[REMOTE] Configurando Systemd Service para NATS Exporter..."
    cat <<EOF > /tmp/nats_exporter.service
[Unit]
Description=NATS Prometheus Exporter
After=network.target

[Service]
User=root
# Flags devem vir ANTES do argumento posicional (URL)
ExecStart=/usr/local/bin/prometheus-nats-exporter -varz -connz -routez -subz -port 7777 http://localhost:8222
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    run_sudo mv /tmp/nats_exporter.service /etc/systemd/system/nats_exporter.service
    run_sudo systemctl stop nats_exporter || true
    run_sudo systemctl daemon-reload
    run_sudo systemctl enable nats_exporter
    run_sudo systemctl start nats_exporter
    
    echo "[REMOTE] Verificando status do NATS Exporter..."
    run_sudo systemctl status nats_exporter --no-pager || echo "[WARN] Status do NATS Exporter indicou falha/aviso."
    echo "[REMOTE] Sucesso! NATS Exporter configurado na porta 7777."

    # --- REDIS EXPORTER ---
    if [ ! -f "/usr/local/bin/redis_exporter" ]; then
        echo "[REMOTE] Baixando Redis Exporter ($display_arch)..."
        REDIS_VER="v1.63.0"
        wget -q "https://github.com/oliver006/redis_exporter/releases/download/$REDIS_VER/redis_exporter-$REDIS_VER.linux-$display_arch.tar.gz"
        tar xvfz "redis_exporter-$REDIS_VER.linux-$display_arch.tar.gz"
        run_sudo mv "redis_exporter-$REDIS_VER.linux-$display_arch/redis_exporter" /usr/local/bin/redis_exporter
        rm -rf "redis_exporter-$REDIS_VER.linux-$display_arch"*
    else
        echo "[REMOTE] Redis Exporter já instalado."
    fi

    echo "[REMOTE] Configurando Systemd Service para Redis Exporter..."
    cat <<EOF > /tmp/redis_exporter.service
[Unit]
Description=Redis Exporter
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/redis_exporter -redis.addr localhost:6379 -web.listen-address :9121
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    run_sudo mv /tmp/redis_exporter.service /etc/systemd/system/redis_exporter.service
    run_sudo systemctl stop redis_exporter || true
    run_sudo systemctl daemon-reload
    run_sudo systemctl enable redis_exporter
    run_sudo systemctl start redis_exporter
    echo "[REMOTE] Sucesso! Redis Exporter rodando na porta 9121."
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
    "port": 9101,
    "checks": [
      {
        "id": "node-exporter-check",
        "name": "Node Exporter HTTP Check",
        "http": "http://localhost:9101/metrics",
        "interval": "10s",
        "timeout": "1s"
      }
    ]
  }
}
EOF
    run_sudo mv /tmp/node-exporter-consul.json /etc/consul.d/node-exporter.json

    # NATS Exporter
    cat <<EOF > /tmp/nats-exporter-consul.json
{
  "service": {
    "name": "nats-exporter",
    "tags": ["metrics", "nats"],
    "port": 7777,
    "checks": [
      {
        "id": "nats-exporter-check",
        "name": "NATS Exporter HTTP Check",
        "http": "http://localhost:7777/metrics",
        "interval": "10s",
        "timeout": "1s"
      }
    ]
  }
}
EOF
    run_sudo mv /tmp/nats-exporter-consul.json /etc/consul.d/nats-exporter.json

    # Redis Exporter
    cat <<EOF > /tmp/redis-exporter-consul.json
{
  "service": {
    "name": "redis-exporter",
    "tags": ["metrics", "redis"],
    "port": 9121,
    "checks": [
      {
        "id": "redis-exporter-check",
        "name": "Redis Exporter HTTP Check",
        "http": "http://localhost:9121/metrics",
        "interval": "10s",
        "timeout": "1s"
      }
    ]
  }
}
EOF
    run_sudo mv /tmp/redis-exporter-consul.json /etc/consul.d/redis-exporter.json
    
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
        print(f"\n[ERRO] Falha na execução remota via SSH (Exit Code: {e.returncode}).")
        print(f"--- SAÍDA PADRÃO (STDOUT) ---\n{e.stdout}")
        print(f"--- SAÍDA DE ERRO (STDERR) ---\n{e.stderr}")

if __name__ == "__main__":
    print("=== Deploy de Agentes de Monitoramento ===")
    print("(Instala: Promtail, Node Exporter, NATS Exporter, Redis Exporter)")
    
    # Lista de alvos pré-definidos
    targets = [
        "192.168.100.51",
        "192.168.100.52",
        "192.168.100.53",
        "192.168.100.54",
        "192.168.100.59"
    ]
    
    user = input("Usuário SSH (ex: labcom) [labcom]: ") or "labcom"
    port = input("Porta SSH [22]: ") or "22"
    ssh_password = getpass.getpass(f"Senha SSH para {user} (será usada em todos os hosts): ")
    
    default_loki = "192.168.1.68"
    loki_ip = input(f"IP do seu PC (Loki Server) [{default_loki}]: ") or default_loki
    
    print(f"\n[INFO] Iniciando deploy em {len(targets)} servidores: {targets}\n")
    
    for host in targets:
        print(f"--------------------------------------------------")
        print(f"DEPLOYING TO: {host}")
        print(f"--------------------------------------------------")
        deploy_remote_agent(host, user, port, ssh_password, loki_ip)
        print("\n")

    print("[DONE] Todos os deploys finalizados.")