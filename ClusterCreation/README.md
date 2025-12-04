# README.md

README – Cluster Platform and Service Discovery
===============================================

This repository contains the Cluster Creation component of the Practical Work.
Our responsibility is to provide a distributed cluster platform that supports all other groups (chat, filesystem, security, chaos).
The platform enables:
- Service registration
- Service discovery
- Health checks
- Node membership tracking
- Leader election

We run a Consul cluster and provide a Python helper (cluster_helper.py) so that all groups can integrate easily.

------------------------------------------------------------
1. What the Cluster Provides
------------------------------------------------------------

- Naming and service registry
- Health checking using HTTP endpoints
- Automatic filtering of unhealthy services
- Discovery of services
- Node membership information
- Leader election

All other groups interact with the cluster through cluster_helper.py.

------------------------------------------------------------
2. Requirements for All Other Groups
------------------------------------------------------------

Each group must:

1. Run their own service (Docker, VM, or local machine).
2. Expose a health endpoint:
   GET /health
   Must return HTTP 200 if the service is healthy.
3. Register their service using our helper.
4. Use discovery to find dependencies (no IP hardcoding).
5. Deregister their service on shutdown.

------------------------------------------------------------
3. Consul Cluster Address
------------------------------------------------------------

Default address used by the helper:
http://172.20.10.10:8500

------------------------------------------------------------
4. Installing and Importing the Helper
------------------------------------------------------------

Install dependency:
pip install requests

Import in your Python service:
from cluster_helper import register_service, deregister_service, discover_service, pick_service_instance, list_nodes, list_services, get_leader, ClusterError

------------------------------------------------------------
5. Registering a Service
------------------------------------------------------------

Call this when your service starts:

register_service(
    name="chat-service",
    service_id="chat-node1",
    address="10.16.148.252",
    port=9000,
    tags=["chat"],
    health_path="/health",
    interval="10s",
    timeout="2s"
)

Important:
- address must be reachable by other machines.
- You MUST expose:
  http://address:port/health
  returning HTTP 200.

------------------------------------------------------------
6. Deregistering a Service
------------------------------------------------------------

Call this before your service shuts down:

deregister_service("chat-node1")

------------------------------------------------------------
7. Discovering Other Services
------------------------------------------------------------

Pick a random healthy instance:

address, port = pick_service_instance("fs-service")

Get all instances of a service:

entries = discover_service("fs-service")
for entry in entries:
    svc = entry["Service"]
    print(svc["ID"], svc["Address"], svc["Port"])

------------------------------------------------------------
8. Cluster Info
------------------------------------------------------------

List nodes:
list_nodes()

List services:
list_services()

Get leader:
get_leader()

------------------------------------------------------------
9. Minimal Working Example (Flask)
------------------------------------------------------------

from flask import Flask, jsonify
from cluster_helper import register_service, deregister_service
import socket, atexit

SERVICE_NAME = "chat-service"
SERVICE_ID = f"{SERVICE_NAME}-{socket.gethostname()}"
HOST_IP = "10.16.148.252"
PORT = 9000

app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({"status": "ok"}), 200

def on_startup():
    register_service(
        name=SERVICE_NAME,
        service_id=SERVICE_ID,
        address=HOST_IP,
        port=PORT,
        tags=["chat"],
        health_path="/health"
    )

def on_shutdown():
    deregister_service(SERVICE_ID)

if __name__ == "__main__":
    on_startup()
    atexit.register(on_shutdown)
    app.run(host="0.0.0.0", port=PORT)

------------------------------------------------------------
10. Naming Conventions (Recommended)
------------------------------------------------------------

chat-service
fs-service
security-service
chaos-service

Example service IDs:
chat-node1
fs-node1
security-nodeA
chaos-node1

------------------------------------------------------------
11. Troubleshooting
------------------------------------------------------------

Problem: Service not showing in discovery
Solution:
- Is /health returning HTTP 200?
- Is the IP reachable?
- Is CONSUL_HTTP_ADDR correct?

Problem: Service marked unhealthy
Solution:
curl http://address:port/health

Problem: ClusterError
- Consul may be down
- Wrong IP
- Service cannot reach Consul

------------------------------------------------------------
12. Summary
------------------------------------------------------------

All groups must:
- Run their service
- Expose /health
- Register using register_service()
- Use pick_service_instance() or discover_service()
- Deregister on shutdown
- Never hardcode IPs

The Cluster Creation group provides:
- Consul cluster
- Naming and service registry
- Service discovery
- Membership tracking
- Leader info
- Helper library
- Documentation

# End of README.md
