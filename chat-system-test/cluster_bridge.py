#!/usr/bin/env python3
"""
Bridge script to register services with the main cluster from bash scripts
Usage: 
  python3 cluster_bridge.py register <service_name> <service_id> <address> <port> <consul_url> <tags>
  python3 cluster_bridge.py deregister <service_id> <consul_url>
"""
import sys

import requests


def register_service(service_name, service_id, address, port, consul_url, tags=""):
    """Register a service with Consul"""
    tag_list = tags.split(',') if tags else []
    
    registration = {
        "ID": service_id,
        "Name": service_name,
        "Address": address,
        "Port": int(port),
        "Tags": tag_list,
        "Check": {
            "TCP": f"{address}:{port}",
            "Interval": "10s",
            "Timeout": "2s",
            "DeregisterCriticalServiceAfter": "30s"
        }
    }
    
    try:
        response = requests.put(
            f"{consul_url}/v1/agent/service/register",
            json=registration,
            timeout=5
        )
        response.raise_for_status()
        print(f"✓ Registered {service_id}")
        return 0
    except requests.exceptions.RequestException as e:
        print(f"✗ Failed to register {service_id}: {e}", file=sys.stderr)
        return 1

def deregister_service(service_id, consul_url):
    """Deregister a service from Consul"""
    try:
        response = requests.put(
            f"{consul_url}/v1/agent/service/deregister/{service_id}",
            timeout=5
        )
        response.raise_for_status()
        print(f"✓ Deregistered {service_id}")
        return 0
    except requests.exceptions.RequestException as e:
        print(f"✗ Failed to deregister {service_id}: {e}", file=sys.stderr)
        return 1

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: cluster_bridge.py <register|deregister> [args...]", file=sys.stderr)
        sys.exit(1)
    
    action = sys.argv[1]
    
    if action == 'register':
        if len(sys.argv) < 7:
            print("Usage: cluster_bridge.py register <service_name> <service_id> <address> <port> <consul_url> <tags>", file=sys.stderr)
            sys.exit(1)
        
        service_name = sys.argv[2]
        service_id = sys.argv[3]
        address = sys.argv[4]
        port = sys.argv[5]
        consul_url = sys.argv[6]
        tags = sys.argv[7] if len(sys.argv) > 7 else ""
        
        sys.exit(register_service(service_name, service_id, address, port, consul_url, tags))
    
    elif action == 'deregister':
        if len(sys.argv) < 4:
            print("Usage: cluster_bridge.py deregister <service_id> <consul_url>", file=sys.stderr)
            sys.exit(1)
        
        service_id = sys.argv[2]
        consul_url = sys.argv[3]
        
        sys.exit(deregister_service(service_id, consul_url))
    
    else:
        print(f"Unknown action: {action}", file=sys.stderr)
        print("Available actions: register, deregister", file=sys.stderr)
        sys.exit(1)
