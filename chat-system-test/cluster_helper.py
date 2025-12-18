#!/usr/bin/env python3
"""
Cluster Helper - Official client for the Consul cluster platform
Provided by the Cluster Creation team for all groups (chat, filesystem, security, chaos)

Install: pip install requests
"""

import random

import requests

CONSUL_URL = "http://192.168.100.53:8500"

class ClusterError(Exception):
    """Custom exception for cluster operations"""
    pass


def register_service(
    name: str,
    service_id: str,
    address: str,
    port: int,
    tags: list = None,
    health_path: str = "/health",
    interval: str = "10s",
    timeout: str = "2s",
    consul_url: str = None,
    check_type: str = "http"
):
    """
    Register a service with Consul.
    
    Args:
        name: Service name (e.g., "chat-service")
        service_id: Unique ID for this instance (e.g., "chat-node1")
        address: IP address reachable by other machines
        port: Service port
        tags: List of tags for filtering
        health_path: HTTP path for health check (must return 200)
        interval: Health check interval
        timeout: Health check timeout
        consul_url: Override default Consul URL
        check_type: "http" for HTTP health check, "tcp" for TCP check
    """
    url = consul_url or CONSUL_URL
    tags = tags or []
    
    # Build check configuration based on type
    if check_type == "tcp":
        check = {
            "TCP": f"{address}:{port}",
            "Interval": interval,
            "Timeout": timeout,
            "DeregisterCriticalServiceAfter": "1m"
        }
    else:
        check = {
            "HTTP": f"http://{address}:{port}{health_path}",
            "Interval": interval,
            "Timeout": timeout,
            "DeregisterCriticalServiceAfter": "1m"
        }
    
    registration = {
        "ID": service_id,
        "Name": name,
        "Address": address,
        "Port": int(port),
        "Tags": tags,
        "Check": check
    }
    
    try:
        response = requests.put(
            f"{url}/v1/agent/service/register",
            json=registration,
            timeout=10
        )
        response.raise_for_status()
        print(f"✓ Registered {service_id} ({name}) at {address}:{port}")
        return True
    except requests.exceptions.RequestException as e:
        raise ClusterError(f"Failed to register {service_id}: {e}")


def deregister_service(service_id: str, consul_url: str = None):
    """
    Deregister a service from Consul.
    
    Args:
        service_id: The service ID to deregister
        consul_url: Override default Consul URL
    """
    url = consul_url or CONSUL_URL
    
    try:
        response = requests.put(
            f"{url}/v1/agent/service/deregister/{service_id}",
            timeout=10
        )
        response.raise_for_status()
        print(f"✓ Deregistered {service_id}")
        return True
    except requests.exceptions.RequestException as e:
        raise ClusterError(f"Failed to deregister {service_id}: {e}")


def discover_service(name: str, passing_only: bool = True, consul_url: str = None):
    """
    Discover all instances of a service.
    
    Args:
        name: Service name to discover
        passing_only: Only return healthy instances
        consul_url: Override default Consul URL
    
    Returns:
        List of service entries
    """
    url = consul_url or CONSUL_URL
    
    try:
        endpoint = f"{url}/v1/health/service/{name}"
        if passing_only:
            endpoint += "?passing=true"
        
        response = requests.get(endpoint, timeout=10)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        raise ClusterError(f"Failed to discover {name}: {e}")


def pick_service_instance(name: str, consul_url: str = None):
    """
    Pick a random healthy instance of a service.
    
    Args:
        name: Service name
        consul_url: Override default Consul URL
    
    Returns:
        Tuple of (address, port) or raises ClusterError if none available
    """
    entries = discover_service(name, passing_only=True, consul_url=consul_url)
    
    if not entries:
        raise ClusterError(f"No healthy instances of {name} found")
    
    entry = random.choice(entries)
    svc = entry["Service"]
    return svc["Address"], svc["Port"]


def list_nodes(consul_url: str = None):
    """
    List all nodes in the cluster.
    
    Returns:
        List of node information
    """
    url = consul_url or CONSUL_URL
    
    try:
        response = requests.get(f"{url}/v1/catalog/nodes", timeout=10)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        raise ClusterError(f"Failed to list nodes: {e}")


def list_services(consul_url: str = None):
    """
    List all registered services.
    
    Returns:
        Dictionary of services
    """
    url = consul_url or CONSUL_URL
    
    try:
        response = requests.get(f"{url}/v1/catalog/services", timeout=10)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        raise ClusterError(f"Failed to list services: {e}")


def get_leader(consul_url: str = None):
    """
    Get the current cluster leader.
    
    Returns:
        Leader address string
    """
    url = consul_url or CONSUL_URL
    
    try:
        response = requests.get(f"{url}/v1/status/leader", timeout=10)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        raise ClusterError(f"Failed to get leader: {e}")


def check_consul_health(consul_url: str = None):
    """
    Check if Consul is reachable.
    
    Returns:
        True if reachable, False otherwise
    """
    url = consul_url or CONSUL_URL
    
    try:
        response = requests.get(f"{url}/v1/agent/self", timeout=5)
        return response.status_code == 200
    except:
        return False


# CLI interface for bash scripts
if __name__ == '__main__':
    import sys
    
    if len(sys.argv) < 2:
        print("Usage: cluster_helper.py <command> [args...]")
        print("Commands: register, deregister, discover, pick, nodes, services, leader, check")
        sys.exit(1)
    
    command = sys.argv[1]
    
    try:
        if command == "register":
            # register <name> <service_id> <address> <port> <consul_url> [tags] [health_path_or_tcp]
            if len(sys.argv) < 7:
                print("Usage: register <name> <service_id> <address> <port> <consul_url> [tags] [health_path or 'tcp']")
                print("  Use 'tcp' as the last argument for TCP health check (for Redis, NATS, etc.)")
                sys.exit(1)
            
            name = sys.argv[2]
            service_id = sys.argv[3]
            address = sys.argv[4]
            port = int(sys.argv[5])
            consul_url = sys.argv[6]
            tags = sys.argv[7].split(',') if len(sys.argv) > 7 and sys.argv[7] else []
            health_path_or_tcp = sys.argv[8] if len(sys.argv) > 8 else "/health"
            
            # Check if TCP health check is requested
            if health_path_or_tcp.lower() == "tcp":
                register_service(name, service_id, address, port, tags, consul_url=consul_url, check_type="tcp")
            else:
                register_service(name, service_id, address, port, tags, health_path_or_tcp, consul_url=consul_url, check_type="http")
            
        elif command == "deregister":
            if len(sys.argv) < 4:
                print("Usage: deregister <service_id> <consul_url>")
                sys.exit(1)
            
            deregister_service(sys.argv[2], consul_url=sys.argv[3])
            
        elif command == "discover":
            if len(sys.argv) < 3:
                print("Usage: discover <service_name> [consul_url]")
                sys.exit(1)
            
            consul_url = sys.argv[3] if len(sys.argv) > 3 else None
            entries = discover_service(sys.argv[2], consul_url=consul_url)
            for entry in entries:
                svc = entry["Service"]
                print(f"{svc['ID']}\t{svc['Address']}\t{svc['Port']}")
                
        elif command == "pick":
            if len(sys.argv) < 3:
                print("Usage: pick <service_name> [consul_url]")
                sys.exit(1)
            
            consul_url = sys.argv[3] if len(sys.argv) > 3 else None
            addr, port = pick_service_instance(sys.argv[2], consul_url=consul_url)
            print(f"{addr}:{port}")
            
        elif command == "nodes":
            consul_url = sys.argv[2] if len(sys.argv) > 2 else None
            for node in list_nodes(consul_url=consul_url):
                print(f"{node['Node']}\t{node['Address']}")
                
        elif command == "services":
            consul_url = sys.argv[2] if len(sys.argv) > 2 else None
            for name, tags in list_services(consul_url=consul_url).items():
                print(f"{name}\t{','.join(tags)}")
                
        elif command == "leader":
            consul_url = sys.argv[2] if len(sys.argv) > 2 else None
            print(get_leader(consul_url=consul_url))
            
        elif command == "check":
            consul_url = sys.argv[2] if len(sys.argv) > 2 else None
            if check_consul_health(consul_url=consul_url):
                print("✓ Consul is reachable")
                sys.exit(0)
            else:
                print("✗ Consul is not reachable")
                sys.exit(1)
                
        else:
            print(f"Unknown command: {command}")
            sys.exit(1)
            
    except ClusterError as e:
        print(f"✗ {e}", file=sys.stderr)
        sys.exit(1)
