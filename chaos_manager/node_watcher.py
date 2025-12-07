import time
import sys
import os
import requests
import threading
from typing import Optional
from pathlib import Path

# Adiciona o diretório pai ao path para importar deploy_agents
sys.path.append(str(Path(__file__).resolve().parent.parent))

from chaos_manager.import_nodes import sync_nodes, CONSUL_ADDR
from deploy_agents import deploy_to_node

def watch_service_changes(name: str, callback, passing_only: bool = True, stop_event: Optional[threading.Event] = None):
    """
    Monitoriza alterações num serviço usando Consul Blocking Queries.
    Invoca `callback(instances)` sempre que a lista de serviços mudar.
    
    :param name: Nome do serviço a monitorizar
    :param callback: Função que recebe a lista de instâncias
    :param passing_only: Se True, só notifica sobre nós saudáveis
    :param stop_event: Evento para parar o watch (opcional)
    """
    print(f"👀 Iniciando Watcher para o serviço: '{name}'...")
    last_index = "0"
    
    while True:
        if stop_event and stop_event.is_set():
            break
            
        params = {
            "wait": "30s",  # Long polling
            "index": last_index
        }
        if passing_only:
            params["passing"] = "true"

        try:
            url = f"{CONSUL_ADDR}/v1/health/service/{name}"
            resp = requests.get(url, params=params, timeout=40)
            
            if resp.status_code == 200:
                # Atualiza o index para a próxima chamada
                new_index = resp.headers.get("X-Consul-Index", "0")
                
                # Se o index mudou, houve alteração (ou timeout do wait)
                if new_index != last_index:
                    print(f"\n🔔 Mudança detectada em '{name}' (Index: {new_index})")
                    last_index = new_index
                    instances = resp.json()
                    callback(instances)
            else:
                print(f"⚠️ Erro na query do Consul ({name}): {resp.status_code}")
                time.sleep(5)

        except requests.exceptions.Timeout:
            pass
        except Exception as e:
            print(f"❌ Erro no loop do watcher ({name}): {e}")
            time.sleep(5)

def run_sync_cycle(instances=None):
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
    print(f"📡 Conectado ao Consul em: {CONSUL_ADDR}")
    
    # Primeira sincronização imediata
    run_sync_cycle()
    
    # Monitoriza o serviço "consul" (que contém o check "Serf Health Status" dos nós)
    # Quando houver alterações, chama run_sync_cycle
    watch_service_changes("consul", run_sync_cycle)
