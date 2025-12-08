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
from deploy_agents import deploy_to_node, load_nodes
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
        # 1) Actualiza nodes.yaml a partir do Consul
        sync_nodes()

        # 2) Carrega nós do ficheiro
        nodes = load_nodes()
        if not nodes:
            print("⚠️ Nenhum nó encontrado para deploy.")
            return

        # 3) Se vieram instâncias do watcher, filtrar só as que estão em falha
        failing_ids = set()
        if instances is not None:
            for inst in instances:
                svc = inst.get("Service", {})
                checks = inst.get("Checks", [])
                status = "passing"
                for chk in checks:
                    if chk.get("CheckID", "").startswith("service:") and chk.get("ServiceID") == svc.get("ID"):
                        status = chk.get("Status", "unknown")
                        break
                if status != "passing":
                    # ServiceID is like "node-exporter-server3" -> node id is after last "-"
                    service_id = svc.get("ID", "")
                    node_id = service_id.replace("node-exporter-", "")
                    failing_ids.add(node_id)

        if failing_ids:
            print(f"❗ Serviços em falha: {sorted(failing_ids)}")
        else:
            print("✅ Nenhum node-exporter em falha; nada para redeploy.")
            return

         # 4) Redeploy só para os nós em falha
        for node in nodes:
            if node["id"] not in failing_ids:
                continue
            if node["host"] in ["127.0.0.1", "localhost", "host.docker.internal"]:
                continue

            try:
                print(f"🚀 (re)deploy node_exporter em {node['id']} ({node['host']}:{node['ssh_port']})")
                deploy_to_node(node)
                # dá tempo ao Consul para voltar a fazer o health-check
                time.sleep(12)
            except Exception as e:
                print(f"❌ Erro ao (re)deployar nó {node['id']}: {e}")
    except Exception as e:
        print(f"❌ Falha na sincronização: {e}")

if __name__ == "__main__":
    print(f"📡 Conectado ao Consul em: {CONSUL_ADDR}")

    # 1) Deploy inicial a TODOS os nós (apenas uma vez)
    try:
        print("🚀 Deploy inicial de node_exporter em todos os nós...")
        sync_nodes()
        all_nodes = load_nodes()
        for node in all_nodes:
            if node["host"] in ["127.0.0.1", "localhost", "host.docker.internal"]:
                continue
            deploy_to_node(node)
    except Exception as e:
        print(f"❌ Erro no deploy inicial: {e}")

    # 2) Depois disso, o watcher só trata FALHAS
    watch_service_changes("node-exporter", run_sync_cycle, passing_only=False)