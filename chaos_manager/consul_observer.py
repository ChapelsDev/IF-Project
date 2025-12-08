import time
import requests
import os
from typing import List, Optional

# Mesma lógica de configuração usada em deploy_agents.py
DEFAULT_SERVERS = "http://192.168.1.70:8500,http://192.168.1.70:8501,http://192.168.1.70:8502"
CONSUL_HTTP_SERVERS = os.getenv("CONSUL_HTTP_SERVERS", DEFAULT_SERVERS)
CONSUL_ADDRESSES: List[str] = [addr.strip() for addr in CONSUL_HTTP_SERVERS.split(",")]

# Mantemos uma compatibilidade com a variável antiga (primeiro servidor)
CONSUL_ADDR = CONSUL_ADDRESSES[0]


def _get_consul_addr(server_index: Optional[int] = None) -> List[str]:
    """
    Se server_index for None -> devolve a lista de TODOS os servidores.
    Se for um índice (0,1,2,...) -> devolve uma lista com apenas esse servidor.
    """
    if server_index is None:
        return CONSUL_ADDRESSES
    if 0 <= server_index < len(CONSUL_ADDRESSES):
        return [CONSUL_ADDRESSES[server_index]]
    # índice inválido -> fallback para o primeiro
    return [CONSUL_ADDRESSES[0]]


def get_consul_nodes(server_index: Optional[int] = None):
    """
    Retorna a lista de nós conhecidos pelo Consul.
    - Se server_index is None: devolve a união dos nós em TODOS os servidores.
    - Se server_index é 0/1/2: consulta apenas esse servidor.
    """
    all_nodes = {}
    addrs = _get_consul_addr(server_index)

    for addr in addrs:
        try:
            resp = requests.get(f"{addr}/v1/catalog/nodes", timeout=5)
            resp.raise_for_status()
            for node in resp.json():
                # usa o nome do nó como chave para não duplicar
                all_nodes[node["Node"]] = node
        except Exception as e:
            print(f"⚠️ Erro ao consultar Consul {addr}: {e}")

    return list(all_nodes.values())


def wait_for_node_removal(node_name: str, timeout: int = 60, server_index: Optional[int] = None):
    """
    Espera até que um nó desapareça da lista do Consul (ou timeout).
    - Se server_index is None: considera removido quando não existir em NENHUM servidor.
    - Se server_index é 0/1/2: considera removido apenas nesse servidor.
    """
    start = time.time()
    addrs = _get_consul_addr(server_index)

    while time.time() - start < timeout:
        all_gone = True

        for addr in addrs:
            try:
                resp = requests.get(f"{addr}/v1/catalog/nodes", timeout=5)
                resp.raise_for_status()
                nodes = resp.json()
                found = any(n["Node"] == node_name for n in nodes)
                if found:
                    all_gone = False
            except Exception as e:
                print(f"⚠️ Erro ao consultar Consul {addr}: {e}")
                all_gone = False

        if all_gone:
            scope = "todos os Consul" if server_index is None else f"Consul {addrs[0]}"
            print(f"✅ Nó '{node_name}' removido de {scope}.")
            return True

        time.sleep(2)

    scope = "todos os Consul" if server_index is None else f"Consul {addrs[0]}"
    print(f"❌ Timeout: Nó '{node_name}' ainda está presente em {scope} após {timeout}s.")
    return False


def wait_for_node_health(
    node_name: str,
    status: str = "passing",
    timeout: int = 60,
    server_index: Optional[int] = None,
):
    """
    Espera até que o check 'serfHealth' do nó atinja o estado desejado.
    Status: passing, warning, critical.

    - Se server_index is None: exige que TODOS os servidores vejam o nó com esse estado.
    - Se server_index é 0/1/2: verifica apenas nesse servidor.
    """
    start = time.time()
    addrs = _get_consul_addr(server_index)

    while time.time() - start < timeout:
        ok_everywhere = True

        for addr in addrs:
            try:
                resp = requests.get(f"{addr}/v1/health/node/{node_name}", timeout=5)
                if resp.status_code != 200:
                    ok_everywhere = False
                    continue

                checks = resp.json()
                serf = next((c for c in checks if c["CheckID"] == "serfHealth"), None)

                if not serf or serf["Status"] != status:
                    ok_everywhere = False
            except Exception as e:
                print(f"⚠️ Erro ao consultar health em {addr}: {e}")
                ok_everywhere = False

        if ok_everywhere:
            scope = "todos os Consul" if server_index is None else f"Consul {addrs[0]}"
            print(f"✅ Nó '{node_name}' atingiu estado '{status}' em {scope}.")
            return True

        time.sleep(2)

    scope = "todos os Consul" if server_index is None else f"Consul {addrs[0]}"
    print(f"❌ Timeout: Nó '{node_name}' não atingiu estado '{status}' em {scope}.")
    return False
