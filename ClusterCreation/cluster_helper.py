import os
import random
import threading
import time
from typing import List, Tuple, Dict, Optional
import requests

# --- AJUSTE: Mudei para 127.0.0.1 para funcionar dentro do Docker ---
NODE_IP = "172.20.10.8" 
CONSUL_HTTP_ADDR = os.getenv("CONSUL_HTTP_ADDR", f"http://{NODE_IP}:8500")

_env_servers = os.getenv("CONSUL_HTTP_SERVERS", "")
if _env_servers:
    CONSUL_HTTP_SERVERS = [entry.strip() for entry in _env_servers.split(",") if entry.strip()]
else:
    CONSUL_HTTP_SERVERS = []

class ClusterError(Exception):
    pass

def _consul_request(method: str, path: str, timeout: int = 10, **kwargs) -> Tuple[requests.Response, str]:
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

def register_service(name: str, service_id: str, address: str, port: int, tags: Optional[List[str]] = None, health_path: str = "/health", interval: str = "10s", timeout: str = "2s", deregister_after: str = "30s", quiet: bool = False, target_url: Optional[str] = None) -> Tuple[str, str]:
    if tags is None: tags = []
    # Nota: Se não tiveres API HTTP, o check vai falhar, mas o registo acontece.
    # Para testes rápidos sem servidor HTTP, podes comentar a secção 'Check' ou usar TTL.
    # Aqui vou assumir TTL para facilitar o teu teste sem precisares de Flask/Webserver.
    
    payload = {
        "Name": name, "ID": service_id, "Address": address, "Port": port, "Tags": tags,
        "Check": {
            "DeregisterCriticalServiceAfter": "1m",
            "TTL": "10s", # Usamos TTL para ser mais fácil testar em consola
            "Status": "passing"
        }
    }

    if target_url:
        server_url = target_url
        try:
            resp = requests.put(f"{server_url.rstrip('/')}/v1/agent/service/register", json=payload, timeout=10)
        except requests.RequestException as e:
            raise ClusterError(f"Connection failed: {e}")
    else:
        resp, server_url = _consul_request("put", "/v1/agent/service/register", json=payload, timeout=10)
    
    if resp.status_code >= 300:
        raise ClusterError(f"Failed to register: {resp.status_code} {resp.text}")
    
    if not quiet:
        print(f"[Cluster] Registado '{service_id}' no nó ({server_url})")
    
    # Inicia thread de heartbeat automática para TTL
    threading.Thread(target=_ttl_heartbeat, args=(service_id,), daemon=True).start()

    return "unknown", server_url

def _ttl_heartbeat(service_id):
    """Mantém o serviço vivo enviando TTL pulses"""
    while True:
        try:
            _consul_request("put", f"/v1/agent/check/pass/service:{service_id}", timeout=2)
        except:
            pass
        time.sleep(5)

def keep_service_registered(name: str, service_id: str, address: str, port: int, tags: Optional[List[str]] = None, resync_interval: int = 10):
    def loop():
        while True:
            try:
                # Tenta registar novamente de X em X tempo para garantir persistência
                register_service(name, service_id, address, port, tags, quiet=True)
            except:
                pass
            time.sleep(resync_interval)
    t = threading.Thread(target=loop, daemon=True)
    t.start()

def deregister_service(service_id: str):
    try:
        _consul_request("put", f"/v1/agent/service/deregister/{service_id}", timeout=2)
        print(f"[Cluster] Serviço {service_id} removido.")
    except:
        pass

def watch_service_changes(name: str, callback, passing_only: bool = True):
    """Blocking Query para detetar mudanças nos serviços"""
    def loop():
        last_index = "0"
        while True:
            params = {"wait": "30s", "index": last_index}
            if passing_only: params["passing"] = "true"
            try:
                resp, _ = _consul_request("get", f"/v1/health/service/{name}", params=params, timeout=40)
                new_index = resp.headers.get("X-Consul-Index", "0")
                if new_index != last_index:
                    last_index = new_index
                    callback(resp.json())
            except Exception:
                time.sleep(5)
    threading.Thread(target=loop, daemon=True).start()

def watch_nodes(callback):
    """
    Blocking Query to detect dead/alive nodes (Infrastructure).
    FIXED: Detects all state changes including simultaneous node resurrections.
    """
    print("[Cluster] Watching Infrastructure (Hardware)...")
    def loop():
        last_index = "0"
        last_known_state = {}  # node_name -> status
        
        while True:
            try:
                params = {"wait": "30s", "index": last_index}
                resp, _ = _consul_request("get", "/v1/health/state/any", params=params, timeout=40)
                
                new_index = resp.headers.get("X-Consul-Index", "0")
                if new_index != last_index:
                    last_index = new_index
                    checks = resp.json()
                    
                    # Build current state: node -> status
                    current_state = {}
                    for c in checks:
                        if c['CheckID'] == 'serfHealth':
                            node = c['Node']
                            status = c['Status']
                            # Keep only the most recent status per node
                            if node not in current_state:
                                current_state[node] = status
                    
                    # Compare with last known state
                    for node, status in current_state.items():
                        prev_status = last_known_state.get(node)
                        
                        # Node state changed
                        if prev_status != status:
                            callback(node, status)
                    
                    # Check for nodes that disappeared (were in last_known_state but not in current_state)
                    disappeared = set(last_known_state.keys()) - set(current_state.keys())
                    for node in disappeared:
                        # Node is gone from Consul (deregistered or completely down)
                        # We could notify as "critical" or just remove from tracking
                        pass
                    
                    # Update state
                    last_known_state = current_state

            except Exception as e:
                print(f"[ClusterHelper] Node watch error: {e}")
                time.sleep(5)
                
    threading.Thread(target=loop, daemon=True).start()