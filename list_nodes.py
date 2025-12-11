import requests
import json
import sys
import yaml
import os

# Configuração
CONSUL_API = "http://172.20.10.8:8500"
NODES_FILE = "config/nodes.yaml"

def get_consul_nodes():
    url = f"{CONSUL_API}/v1/catalog/nodes"
    try:
        print(f"A contactar Consul em {url}...")
        resp = requests.get(url, timeout=5)
        resp.raise_for_status()
        nodes = resp.json()
        return nodes
    except Exception as e:
        print(f"Erro ao contactar Consul: {e}")
        return []

def load_existing_config():
    if os.path.exists(NODES_FILE):
        with open(NODES_FILE, 'r') as f:
            return yaml.safe_load(f) or {"nodes": []}
    return {"nodes": []}

def save_config(config):
    with open(NODES_FILE, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)
    print(f"Ficheiro {NODES_FILE} atualizado.")

def main():
    consul_nodes = get_consul_nodes()
    
    if not consul_nodes:
        print("Nenhum nó encontrado ou erro na conexão.")
        return

    config = load_existing_config()
    existing_nodes = {n['id']: n for n in config.get('nodes', [])}
    
    print(f"\nEncontrados {len(consul_nodes)} nós no Consul.")
    
    updated_count = 0
    for c_node in consul_nodes:
        node_name = c_node.get('Node')
        node_addr = c_node.get('Address')
        
        if node_name in existing_nodes:
            # Atualiza IP se mudou, mantém o resto (credenciais, etc)
            if existing_nodes[node_name]['host'] != node_addr:
                existing_nodes[node_name]['host'] = node_addr
                print(f"Atualizado IP de {node_name} para {node_addr}")
                updated_count += 1
        else:
            # Novo nó
            new_node = {
                "id": node_name,
                "host": node_addr,
                "ssh_user": "root", # Default
                "ssh_port": 22,
                "notes": "Importado automaticamente via list_nodes.py"
            }
            config['nodes'].append(new_node)
            print(f"Adicionado novo nó: {node_name}")
            updated_count += 1

    if updated_count > 0:
        save_config(config)
    else:
        print("Nenhuma alteração necessária no nodes.yaml.")

    # Listagem final
    print("\n--- Inventário Atual (config/nodes.yaml) ---")
    for n in config['nodes']:
        print(f"{n['id']:<15} | {n['host']:<15} | User: {n.get('ssh_user','?')}")

if __name__ == "__main__":
    main()
