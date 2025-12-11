import subprocess
import getpass
import os

def deploy_remote_chaosd(host, user, port, ssh_password, loki_ip="172.20.10.8"):
    print(f"[INFO] A instalar chaosd, node_exporter e promtail em {user}@{host}:{port} ...")

    # Gerar ficheiro de configuração do Promtail
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
          __path__: /var/log/*log
  - job_name: docker
    static_configs:
      - targets:
          - localhost
        labels:
          job: dockerlogs
          __path__: /var/lib/docker/containers/*/*.log
"""
    with open("promtail-config.yaml", "w") as f:
        f.write(promtail_config)

    # Copiar ficheiro para o remoto
    scp_cmd = [
        "sshpass", "-p", ssh_password,
        "scp", "-P", str(port), "promtail-config.yaml",
        f"{user}@{host}:/tmp/promtail-config.yaml"
    ]
    subprocess.run(scp_cmd, check=True)
    os.remove("promtail-config.yaml")

    # Comando remoto
    remote_cmd = f'''
set -e
curl -fsSL https://mirrors.chaos-mesh.org/chaosd-v1.4.0-linux-amd64.tar.gz | tar -xz
sudo mv chaosd-v1.4.0-linux-amd64/chaosd /usr/local/bin/chaosd
sudo pkill chaosd || true
sudo nohup chaosd server --port 31767 --address 0.0.0.0 > chaosd.log 2>&1 &
wget https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
'''
    remote_cmd += '''
tar xvfz node_exporter-1.8.2.linux-amd64.tar.gz
sudo mv node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
sudo pkill node_exporter || true
sudo nohup node_exporter > node_exporter.log 2>&1 &
wget https://github.com/grafana/loki/releases/download/v2.9.4/promtail-linux-amd64.zip
unzip promtail-linux-amd64.zip
sudo mv promtail-linux-amd64 /usr/local/bin/promtail
sudo chmod +x /usr/local/bin/promtail
sudo mv /tmp/promtail-config.yaml /etc/promtail-config.yaml
sudo pkill promtail || true
sudo nohup promtail -config.file=/etc/promtail-config.yaml > promtail.log 2>&1 &
'''
    remote_cmd += '''
docker ps --format 'table {{.Names}}\t{{.ID}}\t{{.Ports}}' | while read line; do
    NAME=$(echo $line | awk '{print $1}')
    if [ "$NAME" != "NAMES" ]; then
        PID=$(docker inspect -f '{{.State.Pid}}' $NAME 2>/dev/null)
        echo "Container: $NAME | PID: $PID"
    fi
done
'''
    ssh_cmd = [
        "sshpass", "-p", ssh_password,
        "ssh", "-p", str(port), f"{user}@{host}", "bash -s"
    ]
    print("[INFO] A executar instalação remota...")
    proc = subprocess.run(ssh_cmd, input=remote_cmd.encode(), check=True)
    print("[INFO] Instalação remota concluída!")

if __name__ == "__main__":
    host = input("Host/IP do nó: ")
    user = input("Utilizador SSH: ")
    port = input("Porta SSH: ")
    ssh_password = getpass.getpass(f"Password SSH para {user}@{host}: ")
    deploy_remote_chaosd(host, user, port, ssh_password)
