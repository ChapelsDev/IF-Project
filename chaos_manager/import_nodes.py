import os
import requests
import yaml
from pathlib import Path

# URL do Consul
CONSUL_ADDR = os.getenv("CONSUL_HTTP_ADDR", "http://192.168.1.196:8500")
# Define project root relative to this file
PROJECT_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = PROJECT_ROOT / "config/nodes.yaml"

def load_existing_config():
    if not CONFIG_PATH.exists():
        return {"nodes": []}
    with open(CONFIG_PATH, "r") as f:
        return yaml.safe_load(f) or {"nodes": []}

import json

def update_prometheus_targets(nodes):
    """Gera o ficheiro JSON para o File Service Discovery do Prometheus."""
    targets = []
    for node in nodes:
        # Extrai host e porta da metrics_url (ex: http://192.168.1.196:9100/metrics)
        if "metrics_url" in node:
            try:
                # Remove http:// e /metrics
                url = node["metrics_url"].replace("http://", "").replace("/metrics", "")
                targets.append({
                    "targets": [url],
                    "labels": {
                        "nodename": node["id"],
                        "job": "chaos_nodes"
                    }
                })
            except Exception:
                pass
    
    target_path = PROJECT_ROOT / "config/prometheus_targets.json"
    with open(target_path, "w") as f:
        json.dump(targets, f, indent=2)
    print(f"Arquivo Prometheus Targets atualizado: {target_path}")

def save_config(data):
    with open(CONFIG_PATH, "w") as f:
        yaml.dump(data, f, sort_keys=False)
    print(f"Arquivo {CONFIG_PATH} atualizado com sucesso!")
    
    # Atualiza também o ficheiro do Prometheus
    update_prometheus_targets(data.get("nodes", []))

def sync_nodes():
    print(f"Conectando ao Consul em: {CONSUL_ADDR}")
    try:
        resp = requests.get(f"{CONSUL_ADDR}/v1/health/service/consul")
        resp.raise_for_status()
        consul_nodes = resp.json()
    except Exception as e:
        print(f"Erro ao conectar ao Consul: {e}")
        return []

    current_config = load_existing_config()
    existing_nodes = {n["id"]: n for n in current_config.get("nodes", [])}
    
    updated_count = 0
    new_count = 0

    # Base SSH port mapping - starts at 2021 for first node
    base_ssh_port = 2021
    
    # Extract external IP from Consul address (this is your Docker host IP)
    external_ip = CONSUL_ADDR.split("://")[1].split(":")[0]  # Gets 192.168.1.70

    for i, entry in enumerate(consul_nodes):
        n = entry["Node"]
        node_id = n["Node"]  # Nome do nó (ex: server1, server2, etc.)
        node_address = n.get("Address", "")  # Internal container IP
        
        print(f"Processando nó: {node_id} (IP interno: {node_address})")
        
        # Calculate SSH port dynamically based on order
        ssh_port = base_ssh_port + i
        
        # For containers, use external IP with mapped SSH ports
        # For actual separate servers, you would use node_address
        if node_address.startswith("172.") or node_address.startswith("10."):
            # This is a container - use external IP with mapped port
            host_address = external_ip
            print(f"  -> Container detectado: usando {host_address}:{ssh_port}")
        else:
            # This might be a separate server - use its actual IP
            host_address = node_address
            ssh_port = 22  # Default SSH port for separate servers
            print(f"  -> Servidor separado detectado: usando {host_address}:{ssh_port}")

        # Calculate metrics port based on SSH port
        metrics_port = 9100 + (ssh_port - base_ssh_port) if ssh_port >= base_ssh_port else 9100

        if node_id in existing_nodes:
            # Update host and port if changed
            if (existing_nodes[node_id].get("host") != host_address or 
                existing_nodes[node_id].get("ssh_port") != ssh_port):
                existing_nodes[node_id]["host"] = host_address
                existing_nodes[node_id]["ssh_port"] = ssh_port
                existing_nodes[node_id]["metrics_url"] = f"http://{host_address}:{metrics_port}/metrics"
                print(f"Atualizado nó existente: {node_id} -> {host_address}:{ssh_port} (metrics: {metrics_port})")
                updated_count += 1
        else:
            # Cria novo nó
            new_node = {
                "id": node_id,
                "host": host_address,
                "ssh_user": "root",
                "ssh_port": ssh_port,
                "net_if": "eth0",
                "metrics_url": f"http://{host_address}:{metrics_port}/metrics",
                "sudo_password": "123456",
                "ssh_password": "123456",
                "notes": f"Importado do Consul - SSH via porta {ssh_port}, metrics na porta {metrics_port}"
            }
            existing_nodes[node_id] = new_node
            print(f"Adicionado novo nó: {node_id} (SSH: {host_address}:{ssh_port}, metrics: {metrics_port})")
            new_count += 1

    # Save the updated configuration
    current_config["nodes"] = list(existing_nodes.values())
    save_config(current_config)
    
    print(f"Sincronização completa: {new_count} novos, {updated_count} atualizados")

def main():
    sync_nodes()

if __name__ == "__main__":
    main()