# cluster_helper.py
import os
import random
from typing import List, Tuple, Dict, Optional

import requests

# Default: Consul na máquina do cluster
CONSUL_HTTP_ADDR = os.getenv("CONSUL_HTTP_ADDR", "http://10.16.148.252:8500")


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

    url = f"{CONSUL_HTTP_ADDR}/v1/agent/service/register"
    resp = requests.put(url, json=payload, timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to register service {service_id}: "
            f"{resp.status_code} {resp.text}"
        )


def deregister_service(service_id: str) -> None:
    """
    Remove um serviço do Consul (chamar no shutdown limpo).
    """
    url = f"{CONSUL_HTTP_ADDR}/v1/agent/service/deregister/{service_id}"
    resp = requests.put(url, timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to deregister service {service_id}: "
            f"{resp.status_code} {resp.text}"
        )


def list_nodes() -> List[Dict]:
    """
    Lista todos os nós conhecidos pelo cluster Consul.
    """
    url = f"{CONSUL_HTTP_ADDR}/v1/catalog/nodes"
    resp = requests.get(url, timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to list nodes: {resp.status_code} {resp.text}"
        )
    return resp.json()


def list_services() -> Dict[str, List[str]]:
    """
    Lista todos os serviços registados (nome -> tags).
    """
    url = f"{CONSUL_HTTP_ADDR}/v1/catalog/services"
    resp = requests.get(url, timeout=5)
    if resp.status_code >= 300:
        raise ClusterError(
            f"Failed to list services: {resp.status_code} {resp.text}"
        )
    return resp.json()


def get_leader() -> str:
    """
    Devolve o líder atual do cluster Consul (endereço Raft).
    """
    url = f"{CONSUL_HTTP_ADDR}/v1/status/leader"
    resp = requests.get(url, timeout=5)
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

    url = f"{CONSUL_HTTP_ADDR}/v1/health/service/{name}"
    resp = requests.get(url, params=params, timeout=5)
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
