# cluster_helper.py
import os
import random
import threading
import time
from typing import List, Tuple, Dict, Optional

import requests

# Default: Consul na máquina do cluster
NODE_IP = "192.168.1.149"
CONSUL_HTTP_ADDR = os.getenv("CONSUL_HTTP_ADDR", f"http://{NODE_IP}:8500")

# Se a env var não estiver definida, usa os 3 servidores por defeito
_env_servers = os.getenv("CONSUL_HTTP_SERVERS", "")
if _env_servers:
    CONSUL_HTTP_SERVERS = [
        entry.strip() for entry in _env_servers.split(",") if entry.strip()
    ]
else:
    CONSUL_HTTP_SERVERS = []

print(f"Consul servers: {CONSUL_HTTP_SERVERS or [CONSUL_HTTP_ADDR]}")


class ClusterError(Exception):
    pass


def register_service(
    name: str,
    service_id: str,
    address: str,
    port: int,
    tags: Optional[List[str]] = None,
    health_path: str = "/health",
    interval: str = "10s",
    timeout: str = "2s",
    deregister_after: str = "30s",
    quiet: bool = False,
    target_url: Optional[str] = None,  
) -> Tuple[str, str]:
    """
    Regista um serviço no Consul.
    """

    if tags is None:
        tags = []

    check_url = f"http://{address}:{port}{health_path}"

    check = {
        "HTTP": check_url,
        "Interval": interval,
        "Timeout": timeout,
    }

    # Só define se quiseres esse comportamento (podes passar None para desativar)
    if deregister_after:
        check["DeregisterCriticalServiceAfter"] = deregister_after

    payload = {
        "Name": name,
        "ID": service_id,
        "Address": address,
        "Port": port,
        "Tags": tags,
        "Check": check,
    }

    if target_url:
        # Direct registration to a specific server
        server_url = target_url
        try:
            resp = requests.put(
                f"{server_url.rstrip('/')}/v1/agent/service/register", 
                json=payload, 
                timeout=5
            )
        except requests.RequestException as e:
            raise ClusterError(f"Connection failed to {server_url}: {e}")
    else:
        # Default behavior: pick a random/available server
        resp, server_url = _consul_request(
            "put", "/v1/agent/service/register", json=payload, timeout=5)
    
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to register service {service_id}: "
            f"{resp.status_code} {resp.text}"
        )
    
    # Try to get the node name from the server we just registered with
    node_name = "unknown"
    try:
        agent_resp = requests.get(f"{server_url}/v1/agent/self", timeout=2)
        if agent_resp.status_code == 200:
            node_name = agent_resp.json().get("Config", {}).get("NodeName", "unknown")
    except Exception:
        pass

    if not quiet:
        print(f"[Cluster] Registered service {service_id} on node '{node_name}' ({server_url})")
    
    return node_name, server_url


def keep_service_registered(
    name: str,
    service_id: str,
    address: str,
    port: int,
    tags: Optional[List[str]] = None,
    health_path: str = "/health",
    interval: str = "10s",
    timeout: str = "2s",
    resync_interval: int = 10,
) -> None:
    """
    Mantém o serviço registado em background.
    Verifica todos os servidores configurados e regista onde estiver em falta.
    """
    def loop():
        while True:
            servers = CONSUL_HTTP_SERVERS or [CONSUL_HTTP_ADDR]
            
            for server in servers:
                try:
                    # 1. Check if service is already registered on this specific agent
                    check_url = f"{server.rstrip('/')}/v1/agent/services"
                    should_register = True
                    
                    try:
                        r = requests.get(check_url, timeout=2)
                        if r.status_code == 200:
                            services = r.json()
                            if service_id in services:
                                should_register = False
                    except requests.RequestException:
                        # If check fails (e.g. timeout), we assume we might need to register
                        # or the node is down. We proceed to try registering below.
                        pass

                    # 2. Register if missing
                    if should_register:
                        register_service(
                            name,
                            service_id,
                            address,
                            port,
                            tags,
                            health_path,
                            interval,
                            timeout,
                            quiet=False, # We want to see when it registers
                            target_url=server
                        )
                except Exception as e:
                    # Suppress errors to avoid spamming if a node is down
                    # print(f"[KeepAlive] Error on {server}: {e}")
                    pass

            time.sleep(resync_interval)

    t = threading.Thread(target=loop, daemon=True)
    t.start()


def deregister_service(service_id: str) -> None:
    """
    Remove um serviço de TODOS os servidores Consul configurados.
    """
    servers = CONSUL_HTTP_SERVERS or [CONSUL_HTTP_ADDR]
    
    for server in servers:
        try:
            url = f"{server.rstrip('/')}/v1/agent/service/deregister/{service_id}"
            requests.put(url, timeout=2)
        except Exception:
            pass
            
    print(f"[Cluster] Deregistered {service_id} from cluster nodes.")


def list_nodes() -> List[Dict]:
    """
    Lista todos os nós conhecidos pelo cluster Consul.
    """
    resp, _ = _consul_request("get", "/v1/catalog/nodes", timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to list nodes: {resp.status_code} {resp.text}"
        )
    return resp.json()


def list_services() -> Dict[str, List[str]]:
    """
    Lista todos os serviços registados (nome -> tags).
    """
    resp, _ = _consul_request("get", "/v1/catalog/services", timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to list services: {resp.status_code} {resp.text}"
        )
    return resp.json()


def get_leader() -> str:
    """
    Devolve o líder atual do cluster Consul (endereço Raft).
    """
    resp, _ = _consul_request("get", "/v1/status/leader", timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to get leader: {resp.status_code} {resp.text}"
        )
    return resp.text.strip('"')


def discover_service(
    name: str,
    passing_only: bool = True,
) -> List[Dict]:
    """
    Descobre instâncias de um serviço pelo nome.

    Retorna uma lista de entradas com informação do serviço e saúde.
    """
    params = {}
    if passing_only:
        params["passing"] = "true"

    resp, _ = _consul_request(
        "get", f"/v1/health/service/{name}", params=params, timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to discover service {name}: "
            f"{resp.status_code} {resp.text}"
        )
    return resp.json()


def pick_service_instance(
    name: str,
    strategy: str = "random",
) -> Tuple[str, int]:
    """
    Escolhe uma instância de um serviço (address, port)
    usando uma estratégia simples (por agora só 'random').
    """
    entries = discover_service(name, passing_only=True)
    if not entries:
        raise ClusterError(f"No healthy instances of service '{name}'")

    if strategy == "random":
        chosen = random.choice(entries)
    else:
        # no futuro podes implementar round-robin, etc.
        chosen = entries[0]

    svc = chosen["Service"]
    return svc["Address"], svc["Port"]


def _consul_request(method: str, path: str, timeout: int = 5, **kwargs) -> Tuple[requests.Response, str]:
    """Executa uma chamada ao Consul tentando múltiplos servidores."""

    servers = CONSUL_HTTP_SERVERS or [CONSUL_HTTP_ADDR]
    candidates = servers.copy()
    random.shuffle(candidates)

    errors = []

    for base in candidates:
        url = f"{base.rstrip('/')}{path}"
        try:
            response = requests.request(method, url, timeout=timeout, **kwargs)
        except requests.RequestException as exc:
            errors.append(f"{base}: {exc}")
            continue

        if response.status_code < 300:
            return response, base

        errors.append(f"{base}: {response.status_code} {response.text}")

    raise ClusterError("; ".join(errors) or "No Consul servers configured")

    
def watch_service_changes(name: str, callback, passing_only: bool = True, stop_event: Optional[threading.Event] = None):
    """
    Monitoriza alterações num serviço usando Consul Blocking Queries.
    Invoca `callback(instances)` sempre que a lista de serviços mudar.
    
    :param name: Nome do serviço a monitorizar
    :param callback: Função que recebe a lista de instâncias (mesmo formato de discover_service)
    :param passing_only: Se True, só notifica sobre nós saudáveis
    :param stop_event: Evento para parar o watch (opcional)
    """
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
            # Usamos _consul_request mas precisamos de acesso aos headers da resposta
            # Como _consul_request retorna (response, url), funciona bem.
            resp, _ = _consul_request("get", f"/v1/health/service/{name}", params=params, timeout=40)
            
            # Atualiza o index para a próxima chamada
            new_index = resp.headers.get("X-Consul-Index", "0")
            
            # Se o index mudou, houve alteração (ou timeout do wait)
            if new_index != last_index:
                last_index = new_index
                instances = resp.json()
                callback(instances)
                
        except Exception as e:
            print(f"[ClusterHelper] Watch error: {e}")
            time.sleep(5) # Espera antes de tentar de novo em caso de erro