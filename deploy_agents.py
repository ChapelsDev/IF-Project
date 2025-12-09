import os
import requests
import yaml

from chaos_manager.ssh_executor import SSHExecutor, NodeSSHConfig

NODE_EXPORTER_URL = "https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz"
INSTALL_DIR = "/tmp/chaos_agent"

DEFAULT_SERVERS = "http://192.168.1.196:8500,http://192.168.1.196:8501,http://192.168.1.196:8502,http://192.168.1.196:8503,http://192.168.1.196:8504"
CONSUL_HTTP_SERVERS = os.getenv("CONSUL_HTTP_SERVERS", DEFAULT_SERVERS)
CONSUL_ADDRESSES = [addr.strip() for addr in CONSUL_HTTP_SERVERS.split(",")]


def load_nodes():
    with open("config/nodes.yaml") as f:
        return yaml.safe_load(f)["nodes"]


def get_metrics_port(ssh_port: int) -> int:
    """Map SSH port to metrics port (2021→9100, 2022→9101, 2023→9102)."""
    return 9100 + (ssh_port - 2021)


def deregister_from_all(node_id: str):
    service_id = f"node-exporter-{node_id}"
    print(f"🧹 Deregistar {service_id} em todos os Consul...")

    for addr in DEFAULT_SERVERS.split(","):
        try:
            url = f"{addr}/v1/agent/service/deregister/{service_id}"
            r = requests.put(url, timeout=5)
            if r.status_code == 200:
                print(f"  ✔ {addr}")
            else:
                print(f"  ⚠ {addr}: {r.status_code}")
        except Exception as e:
            print(f"  ⚠ {addr}: {e}")


def register_in_consul(node_id: str, node_host: str, metrics_port: int, ssh_port: int):
    base_port = 2021
    idx = ssh_port - base_port
    # Usa módulo para distribuir ciclicamente entre os servidores disponíveis
    consul_addr = CONSUL_ADDRESSES[idx % len(CONSUL_ADDRESSES)]

    payload = {
        "ID": f"node-exporter-{node_id}",
        "Name": "node-exporter",
        "Address": node_host,
        "Port": metrics_port,
        "Check": {
            "HTTP": f"http://{node_host}:{metrics_port}/metrics",
            "Interval": "10s",
            "Timeout": "5s",
        },
    }

    url = f"{consul_addr}/v1/agent/service/register"
    r = requests.put(url, json=payload, timeout=5)
    r.raise_for_status()
    print(f"📝 Registado {node_id} em {consul_addr} porta {metrics_port}")


def _ensure_node_exporter_on_remote(executor: SSHExecutor):
    executor.run(f"mkdir -p {INSTALL_DIR}")
    code, _, _ = executor.run(f"test -x {INSTALL_DIR}/node_exporter")
    if code == 0:
        return

    print("⬇️  Descarregar node_exporter...")
    executor.run(f"curl -L {NODE_EXPORTER_URL} -o {INSTALL_DIR}/node_exporter.tar.gz")
    extractor = (
        f"tar -xzf {INSTALL_DIR}/node_exporter.tar.gz -C {INSTALL_DIR} --strip-components=1 "
        f"&& rm -f {INSTALL_DIR}/node_exporter.tar.gz"
    )
    code, out, err = executor.run(extractor)
    if code != 0:
        raise RuntimeError(f"Falha ao extrair node_exporter: {out} {err}")


def deploy_to_node(node: dict):
    node_id = node["id"]
    host = node["host"]
    ssh_port = int(node["ssh_port"])
    user = node.get("ssh_user", "root")
    password = node.get("ssh_password")

    print(f"\n🚀 Deploy node-exporter -> {node_id} ({host}:{ssh_port})")

    cfg = NodeSSHConfig(host=host, user=user, port=ssh_port, password=password)
    ex = SSHExecutor(cfg)

    metrics_port = get_metrics_port(ssh_port)

    # Kill anything old on that port
    ex.run("pkill -f node_exporter || true")
    ex.run(f"fuser -k {metrics_port}/tcp || true")

    _ensure_node_exporter_on_remote(ex)

    # This is exactly the command you ran manually
    start_cmd = (
        f"nohup {INSTALL_DIR}/node_exporter "
        f"--web.listen-address=:{metrics_port} "
        f"> /tmp/node_exporter_{metrics_port}.log 2>&1 &"
    )
    code, out, err = ex.run(start_cmd)
    print("   start:", code, out, err)
    if code != 0:
        print(f"❌ Falha a iniciar node_exporter em {node_id}")
        return

    print(f"  ✔ node_exporter iniciado em :{metrics_port}")

    deregister_from_all(node_id)
    register_in_consul(node_id, host, metrics_port, ssh_port)


def main():
    for node in load_nodes():
        if node["host"] in ["127.0.0.1", "localhost", "host.docker.internal"]:
            continue
        deploy_to_node(node)


if __name__ == "__main__":
    main()
