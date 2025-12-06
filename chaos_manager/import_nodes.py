import os
import requests
import yaml
from pathlib import Path

# URL do Consul
CONSUL_ADDR = os.getenv("CONSUL_HTTP_ADDR", "http://host.docker.internal:8500")
CONFIG_PATH = Path("config/nodes.yaml")

def load_existing_config():
    if not CONFIG_PATH.exists():
        return {"nodes": []}
    with open(CONFIG_PATH, "r") as f:
        return yaml.safe_load(f) or {"nodes": []}

def save_config(data):
    with open(CONFIG_PATH, "w") as f:
        yaml.dump(data, f, sort_keys=False)
    print(f"Arquivo {CONFIG_PATH} atualizado com sucesso!")

def main():
    print(f"Conectando ao Consul em: {CONSUL_ADDR}")
    try:
        resp = requests.get(f"{CONSUL_ADDR}/v1/health/service/consul")
        resp.raise_for_status()
        consul_nodes = resp.json()
    except Exception as e:
        print(f"Erro ao conectar ao Consul: {e}")
        return

    current_config = load_existing_config()
    existing_nodes = {n["id"]: n for n in current_config.get("nodes", [])}
    
    updated_count = 0
    new_count = 0

    for entry in consul_nodes:
        n = entry["Node"]
        node_id = n["Node"] # Nome do nó (ex: server1)
        address = n["Address"]

        if node_id in existing_nodes:
            # Atualiza IP se mudou, mantendo credenciais
            if existing_nodes[node_id].get("host") != address:
                existing_nodes[node_id]["host"] = address
                print(f"Atualizado IP do nó existente: {node_id} -> {address}")
                updated_count += 1
        else:
            # Cria novo nó
            new_node = {
                "id": node_id,
                "host": address,
                "ssh_user": "root",        # Default
                "ssh_port": 22,
                "net_if": "eth0",
                "metrics_url": f"http://{address}:9100/metrics",
                "sudo_password": "CHANGE_ME",
                "notes": "Importado do Consul"
            }
            existing_nodes[node_id] = new_node
            print(f"Adicionado novo nó: {node_id}")
            new_count += 1

    # Reconstrói a lista
    current_config["nodes"] = list(existing_nodes.values())
    save_config(current_config)
    print(f"\nResumo: {new_count} novos, {updated_count} atualizados.")

if __name__ == "__main__":
    main()
