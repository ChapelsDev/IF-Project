# cluster_helper.py
import os
import random
from typing import List, Tuple, Dict, Optional

import requests

# Default: Consul na máquina do cluster
CONSUL_HTTP_ADDR = os.getenv("CONSUL_HTTP_ADDR", "http://172.20.10.10:8500")

# Se a env var não estiver definida, usa os 3 servidores por defeito
_env_servers = os.getenv("CONSUL_HTTP_SERVERS", "")
if _env_servers:
    CONSUL_HTTP_SERVERS = [
        entry.strip() for entry in _env_servers.split(",") if entry.strip()
    ]
else:
    CONSUL_HTTP_SERVERS = [
        "http://172.20.10.10:8500",
        "http://172.20.10.10:8501",
        "http://172.20.10.10:8502",
    ]

print(f"Consul servers: {CONSUL_HTTP_SERVERS}")


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
) -> None:
    """
    Regista um serviço no Consul.

    :param name: Nome lógico do serviço (ex: "chat-service")
    :param service_id: ID único da instância (ex: "chat-node1")
    :param address: IP onde o serviço está a correr
    :param port: Porta onde o serviço está a ouvir
    :param tags: Lista de tags (ex: ["chat"])
    :param health_path: Caminho HTTP para health check (ex: "/health")
    :param interval: Intervalo entre health checks (ex: "10s")
    :param timeout: Timeout do health check (ex: "2s")
    """
    if tags is None:
        tags = []

    check_url = f"http://{address}:{port}{health_path}"

    payload = {
        "Name": name,
        "ID": service_id,
        "Address": address,
        "Port": port,
        "Tags": tags,
        "Check": {
            "HTTP": check_url,
            "Interval": interval,
            "Timeout": timeout,
        },
    }

    resp = _consul_request("put", "/v1/agent/service/register", json=payload, timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to register service {service_id}: "
            f"{resp.status_code} {resp.text}"
        )


def deregister_service(service_id: str) -> None:
    """
    Remove um serviço do Consul (chamar no shutdown limpo).
    """
    resp = _consul_request("put", f"/v1/agent/service/deregister/{service_id}", timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to deregister service {service_id}: "
            f"{resp.status_code} {resp.text}"
        )


def list_nodes() -> List[Dict]:
    """
    Lista todos os nós conhecidos pelo cluster Consul.
    """
    resp = _consul_request("get", "/v1/catalog/nodes", timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to list nodes: {resp.status_code} {resp.text}"
        )
    return resp.json()


def list_services() -> Dict[str, List[str]]:
    """
    Lista todos os serviços registados (nome -> tags).
    """
    resp = _consul_request("get", "/v1/catalog/services", timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to list services: {resp.status_code} {resp.text}"
        )
    return resp.json()


def get_leader() -> str:
    """
    Devolve o líder atual do cluster Consul (endereço Raft).
    """
    resp = _consul_request("get", "/v1/status/leader", timeout=5)
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

    resp = _consul_request("get", f"/v1/health/service/{name}", params=params, timeout=5)
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


def _consul_request(method: str, path: str, timeout: int = 5, **kwargs) -> requests.Response:
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
            return response

        errors.append(f"{base}: {response.status_code} {response.text}")

    raise ClusterError("; ".join(errors) or "No Consul servers configured")
