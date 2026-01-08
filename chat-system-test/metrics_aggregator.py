#!/usr/bin/env python3
"""
Metrics Aggregator - Queries Consul for all chat-service instances and aggregates their metrics
Usage: python3 metrics_aggregator.py [consul_url]
"""
import sys

import requests


def aggregate_metrics(consul_url="http://192.168.100.53:8500"):
    """Aggregate metrics from all registered chat-service instances"""
    try:
        # Discover all healthy chat-service instances
        response = requests.get(f"{consul_url}/v1/health/service/chat-service?passing=true", timeout=5)
        response.raise_for_status()
        instances = response.json()
        
        if not instances:
            print("# No healthy chat-service instances found")
            return
        
        # Collect metrics from each instance
        total_connections = 0
        instance_metrics = []
        
        for entry in instances:
            svc = entry['Service']
            service_id = svc['ID']
            address = svc['Address']
            port = svc['Port']
            
            try:
                metrics_response = requests.get(f"http://{address}:{port}/metrics", timeout=2)
                if metrics_response.status_code == 200:
                    instance_metrics.append(metrics_response.text)
                    # Parse connection count
                    for line in metrics_response.text.split('\n'):
                        if line.startswith('chat_connections_total'):
                            conn_count = int(line.split()[-1])
                            total_connections += conn_count
            except Exception as e:
                print(f"# Warning: Could not fetch metrics from {service_id} at {address}:{port}: {e}")
        
        # Output aggregated metrics
        print("# HELP chat_total_connections_aggregate Total connections across all chat nodes")
        print("# TYPE chat_total_connections_aggregate gauge")
        print(f"chat_total_connections_aggregate {total_connections}")
        print()
        print(f"# HELP chat_instances_total Total number of healthy chat service instances")
        print(f"# TYPE chat_instances_total gauge")
        print(f"chat_instances_total {len(instances)}")
        print()
        
        # Output per-instance metrics
        for metrics in instance_metrics:
            print(metrics)
            print()
            
    except Exception as e:
        print(f"# Error: Failed to aggregate metrics: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    consul_url = sys.argv[1] if len(sys.argv) > 1 else "http://192.168.100.53:8500"
    aggregate_metrics(consul_url)
