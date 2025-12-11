import subprocess
import os

def main(loki_ip="172.20.10.8"):
    print("[INFO] A instalar chaosd, node_exporter e promtail localmente...")

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
    with open("/tmp/promtail-config.yaml", "w") as f:
        f.write(promtail_config)

    cmds = [
        # Instalar dependências básicas
        "apt-get update && apt-get install -y curl wget unzip sudo",
        # Instalar chaosd
        "curl -fsSL https://mirrors.chaos-mesh.org/chaosd-v1.4.0-linux-amd64.tar.gz | tar -xz",
        "sudo mv chaosd-v1.4.0-linux-amd64/chaosd /usr/local/bin/chaosd",
        "sudo pkill chaosd || true",
        "sudo nohup chaosd server --port 31767 --address 0.0.0.0 > chaosd.log 2>&1 &",
        # Instalar node_exporter
        "wget https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz",
        "tar xvfz node_exporter-1.8.2.linux-amd64.tar.gz",
        "sudo mv node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/",
        "sudo pkill node_exporter || true",
        "sudo nohup node_exporter > node_exporter.log 2>&1 &",
        # Instalar promtail
        "wget https://github.com/grafana/loki/releases/download/v2.9.4/promtail-linux-amd64.zip",
        "unzip promtail-linux-amd64.zip",
        "sudo mv promtail-linux-amd64 /usr/local/bin/promtail",
        "sudo chmod +x /usr/local/bin/promtail",
        "sudo mv /tmp/promtail-config.yaml /etc/promtail-config.yaml",
        "sudo pkill promtail || true",
        "sudo nohup promtail -config.file=/etc/promtail-config.yaml > promtail.log 2>&1 &"
    ]

    for cmd in cmds:
        print(f"[CMD] {cmd}")
        subprocess.run(cmd, shell=True, check=True)

    print("[INFO] Serviços instalados e iniciados!")
    print("[INFO] PIDs dos containers Docker:")
    subprocess.run(
        "docker ps --format 'table {{.Names}}\t{{.ID}}\t{{.Ports}}' | while read line; do "
        "NAME=$(echo $line | awk '{print $1}'); "
        "if [ \"$NAME\" != \"NAMES\" ]; then "
        "PID=$(docker inspect -f '{{.State.Pid}}' $NAME 2>/dev/null); "
        "echo \"Container: $NAME | PID: $PID\"; fi; done",
        shell=True
    )

if __name__ == "__main__":
    main()
