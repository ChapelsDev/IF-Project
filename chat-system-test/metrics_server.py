#!/usr/bin/env python3
"""
Metrics Aggregation Server
Exposes aggregated metrics from all chat nodes via HTTP
Usage: python3 metrics_server.py [consul_url] [port]
"""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

import requests

CONSUL_URL = sys.argv[1] if len(sys.argv) > 1 else "http://192.168.100.53:8500"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 9090

def aggregate_metrics():
    """Aggregate metrics from all registered chat-service instances"""
    try:
        # Discover all healthy chat-service instances
        response = requests.get(f"{CONSUL_URL}/v1/health/service/chat-service?passing=true", timeout=5)
        response.raise_for_status()
        instances = response.json()
        
        if not instances:
            return "# No healthy chat-service instances found\n"
        
        # Collect metrics from each instance
        total_connections = 0
        instance_metrics = []
        
        for entry in instances:
            svc = entry['Service']
            service_id, address, port = svc['ID'], svc['Address'], svc['Port']
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
                print(f"Warning: Could not fetch from {service_id}: {e}", file=sys.stderr)
        
        # Build aggregated metrics
        metrics = []
        metrics.append("# HELP chat_total_connections_aggregate Total connections across all nodes")
        metrics.append("# TYPE chat_total_connections_aggregate gauge")
        metrics.append(f"chat_total_connections_aggregate {total_connections}")
        metrics.append("")
        metrics.append("# HELP chat_instances_total Total number of healthy chat service instances")
        metrics.append("# TYPE chat_instances_total gauge")
        metrics.append(f"chat_instances_total {len(instances)}")
        metrics.append("")
        
        # Add per-instance metrics
        for m in instance_metrics:
            metrics.append(m)
            metrics.append("")
        
        return "\n".join(metrics)
    except Exception as e:
        return f"# Error aggregating metrics: {e}\n"

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/metrics':
            metrics = aggregate_metrics()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            self.wfile.write(metrics.encode('utf-8'))
        elif self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"healthy","service":"metrics-aggregator"}')
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not Found')
    
    def log_message(self, format, *args):
        # Log to stderr
        sys.stderr.write(f"{self.address_string()} - {format % args}\n")

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', PORT), MetricsHandler)
    print(f"🚀 Metrics Aggregation Server started")
    print(f"   Port: {PORT}")
    print(f"   Consul: {CONSUL_URL}")
    print(f"   Metrics: http://localhost:{PORT}/metrics")
    print(f"   Health: http://localhost:{PORT}/health")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Shutting down...")
        server.shutdown()
