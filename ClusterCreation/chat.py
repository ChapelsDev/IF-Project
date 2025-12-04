# chat_example.py
import atexit
import socket
import time
from flask import Flask, jsonify, request

from cluster_helper import register_service, deregister_service, pick_service_instance, discover_service, get_leader, list_services, list_nodes

# Configuração básica
SERVICE_NAME = "chat-service"
SERVICE_ID = "chat-node1"
SERVICE_PORT = 9000

# Descobrir IP local (podes também pôr estático)
HOST_IP = socket.gethostbyname(socket.gethostname())

app = Flask(__name__)

start_time = time.time()
connected_clients = 0
messages_total = 0


@app.get("/health")
def health():
    return jsonify(status="ok"), 200


@app.route("/metrics")
def metrics():
    uptime = int(time.time() - start_time)
    return jsonify(
        service_name=SERVICE_NAME,
        instance_id=SERVICE_ID,
        uptime_seconds=uptime,
        connected_clients=connected_clients,
        messages_total=messages_total,
    ), 200


@app.route("/send_message", methods=["POST"])
def send_message():
    global messages_total
    data = request.get_json(force=True, silent=True) or {}
    messages_total += 1
    # aqui seria onde tratavas a mensagem, broadcast, etc.
    return jsonify(status="received", message=data), 200


def main():
    # 1. Registar no Consul
    print(f"Registering {SERVICE_NAME} ({SERVICE_ID}) at {HOST_IP}:{SERVICE_PORT}...")
    register_service(
        name=SERVICE_NAME,
        service_id=SERVICE_ID,
        address=HOST_IP,
        port=SERVICE_PORT,
        tags=["chat"],
        health_path="/health",
        interval="10s",
        timeout="5s"
    )

    print(f"Current leader: {get_leader()}")
    print(f"Known nodes: {list_nodes()}")
    print(f"Registered services: {list_services()}")
    print("Service discovery example:", discover_service("chat"))

    # 2. Garantir deregisto no shutdown
    def cleanup():
        print(f"Deregistering {SERVICE_ID}...")
        try:
            deregister_service(SERVICE_ID)
        except Exception as e:
            print("Error during deregistration:", e)

    atexit.register(cleanup)

    # 3. Arrancar servidor HTTP
    app.run(host="0.0.0.0", port=SERVICE_PORT)


if __name__ == "__main__":
    main()
