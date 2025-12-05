from dotenv import load_dotenv
# Load env vars once at the top
load_dotenv()

from cluster_helper import keep_service_registered, deregister_service
from flask import Flask
import os
import sys
import signal
import atexit

app = Flask(__name__)

# ----- CONFIG -----

# Name of the service as seen in Consul
SERVICE_NAME = "status-service"

# HTTP port where this service will listen on the node
SERVICE_PORT = int(os.getenv("SERVICE_PORT", 9100))

# IP address of THIS NODE (must be reachable by other nodes)
NODE_IP = os.getenv("NODE_IP")
if not NODE_IP:
    # fallback: best-effort local IP
    NODE_IP = "127.0.0.1"

# Unique ID for this instance in Consul
SERVICE_ID = f"{SERVICE_NAME}-{NODE_IP}-{SERVICE_PORT}"

print(
    f"[Status] Starting {SERVICE_NAME} on {NODE_IP}:{SERVICE_PORT} with ID {SERVICE_ID}")


# ----- CLUSTER REGISTRATION -----

def start_consul_registration():
    """
    Starts a background thread that keeps the service registered in Consul.
    Uses the keep_service_registered helper from cluster_helper.py
    """
    keep_service_registered(
        name=SERVICE_NAME,
        service_id=SERVICE_ID,
        address=NODE_IP,
        port=SERVICE_PORT,
        tags=["status"],    # Ensure this is a list
        health_path="/health",
        interval="10s",     # health check interval
        timeout="2s",       # health check timeout
        resync_interval=10,  # how often to re-register
    )


def leave_cluster(*_args):
    """
    Deregister from Consul cleanly on shutdown.
    """
    try:
        deregister_service(SERVICE_ID)
        print("[Cluster] Deregistered", SERVICE_ID)
    except Exception as e:
        print("[Cluster] Failed to deregister:", e)
    finally:
        sys.exit(0)


atexit.register(leave_cluster)
signal.signal(signal.SIGINT, leave_cluster)
signal.signal(signal.SIGTERM, leave_cluster)


# ----- HTTP ENDPOINTS -----

@app.get("/health")
def health():
    return "OK", 200


@app.get("/")
def index():
    return f"Hello from {SERVICE_NAME} at {NODE_IP}:{SERVICE_PORT}\n", 200


# ----- MAIN -----

if __name__ == "__main__":
    # Start registration loop BEFORE starting HTTP server
    start_consul_registration()

    # Start Flask app
    app.run(host="0.0.0.0", port=SERVICE_PORT)
