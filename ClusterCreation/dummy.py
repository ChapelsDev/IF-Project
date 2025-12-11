import sys
import socket
import uuid
import atexit
import cluster_helper  # Import the helper
from http.server import BaseHTTPRequestHandler, HTTPServer
import json

# --- CONFIGURATION ---
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9000
SERVICE_NAME = "dummy"
MY_HOSTNAME = socket.gethostname()
# Use local IP or 127.0.0.1 if testing locally
MY_IP = "172.20.10.8" 
SERVICE_ID = f"{SERVICE_NAME}-{MY_HOSTNAME}-{uuid.uuid4().hex[:4]}"

# --- REGISTRATION ---
def register_myself():
    print(f"🚀 Registering {SERVICE_ID} on port {PORT}...")
    try:
        # Register with TTL check (handled by cluster_helper's background thread)
        cluster_helper.register_service(
            name=SERVICE_NAME,
            service_id=SERVICE_ID,
            address=MY_IP,
            port=PORT,
            tags=["dummy", "v1"]
        )
    except Exception as e:
        print(f"⚠️ Registration failed: {e}")

def deregister_myself():
    print(f"\n🛑 Deregistering {SERVICE_ID}...")
    cluster_helper.deregister_service(SERVICE_ID)

# Register cleanup on exit
atexit.register(deregister_myself)

# --- HTTP SERVER ---
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            # Consul health check (optional if using TTL, but good practice)
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        elif self.path.startswith("/msg"):
            # Dummy message endpoint
            msg = f"Hello from dummy service on port {PORT}!"
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"response": msg}).encode())
        else:
            self.send_response(404)
            self.end_headers()

# --- MAIN ---
if __name__ == "__main__":
    # 1. Register with Consul
    register_myself()
    
    # 2. Start Server
    print(f"✅ Dummy service running on {MY_IP}:{PORT}")
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass # atexit will handle deregistration