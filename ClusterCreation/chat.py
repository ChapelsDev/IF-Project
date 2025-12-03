import requests
 
CONSUL_ADDR = "http://10.16.148.252:8500"  # machine A IP
SERVICE_NAME = "chat-service"
SERVICE_ID = "chat-b1"
SERVICE_ADDR = "10.16.148.252"  # this machine IP
SERVICE_PORT = 9000
 
payload = {
    "Name": SERVICE_NAME,
    "ID": SERVICE_ID,
    "Address": SERVICE_ADDR,
    "Port": SERVICE_PORT,
    "Tags": ["chat"],
    "Check": {
        "HTTP": f"http://{SERVICE_ADDR}:{SERVICE_PORT}/health",
        "Interval": "10s",
        "Timeout": "2s"
    }
}
 
r = requests.put(f"{CONSUL_ADDR}/v1/agent/service/register", json=payload)
print("Register status:", r.status_code, r.text)