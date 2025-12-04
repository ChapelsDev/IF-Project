import requests
import random

CONSUL_ADDR = "http://10.16.148.252:8500"
SERVICE_NAME = "chat-service"

def main():
    # 1. Ask Consul for healthy chat-service instances
    r = requests.get(
        f"{CONSUL_ADDR}/v1/health/service/{SERVICE_NAME}",
        params={"passing": "true"},
        timeout=5
    )
    services = r.json()
    print("Raw Consul response:", services)

    if not services:
        print("No healthy instances found for chat-service")
        return

    # 2. Pick one instance
    inst = random.choice(services)["Service"]
    addr = inst["Address"]
    port = inst["Port"]
    print(f"Picked instance: {addr}:{port}")

    # 3. Call /health on that instance (through discovery result)
    url = f"http://{addr}:{port}/health"
    resp = requests.get(url, timeout=5)
    print("Health status from discovered instance:", resp.status_code, resp.text)

if __name__ == "__main__":
    main()
