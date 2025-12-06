import time
import sys
import os
import requests
from pathlib import Path

# Adiciona o diretório pai ao path para importar deploy_agents
sys.path.append(str(Path(__file__).resolve().parent.parent))

from chaos_manager.import_nodes import sync_nodes, CONSUL_ADDR
from deploy_agents import deploy_to_node

def watch_nodes_blocking():
    print(f"👀 Iniciando Watcher de Nós (Modo Real-Time)...")
    print(f"📡 Conectado ao Consul em: {CONSUL_ADDR}")
    
    last_index = "0"
    
    # Primeira sincronização imediata
    run_sync_cycle()

    while True:
        try:
            # Blocking Query para o serviço "consul" (que representa os nós)
            params = {
                "index": last_index,
                "wait": "30s",
                "passing": "true"
            }
            
            # Nota: Usamos o endpoint de health service para pegar mudanças de status também
            url = f"{CONSUL_ADDR}/v1/health/service/consul"
            
            resp = requests.get(url, params=params, timeout=40)
            
            if resp.status_code == 200:
                new_index = resp.headers.get("X-Consul-Index", "0")
                
                # Se o index mudou, algo aconteceu no cluster
                if new_index != last_index:
                    print(f"\n🔔 Mudança detectada no cluster (Index: {new_index})")
                    last_index = new_index
                    run_sync_cycle()
            else:
                print(f"⚠️ Erro na query do Consul: {resp.status_code}")
                time.sleep(5)

        except requests.exceptions.Timeout:
            # Timeout normal do long polling, apenas continua
            pass
        except Exception as e:
            print(f"❌ Erro no loop do watcher: {e}")
            time.sleep(5)

def run_sync_cycle():
    try:
        print("🔄 Sincronizando inventário...")
        nodes = sync_nodes()
        
        if nodes:
            for node in nodes:
                # Ignora localhost
                if node["host"] in ["127.0.0.1", "localhost", "host.docker.internal"]:
                    continue
                    
                try:
                    # deploy_agents verifica se já está rodando, então é seguro chamar sempre
                    deploy_to_node(node)
                except Exception as e:
                    print(f"❌ Erro ao verificar nó {node['id']}: {e}")
    except Exception as e:
        print(f"❌ Falha na sincronização: {e}")

if __name__ == "__main__":
    watch_nodes_blocking()
