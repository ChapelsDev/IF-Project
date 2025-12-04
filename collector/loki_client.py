from __future__ import annotations
import requests
from datetime import datetime
from typing import Any


class LokiClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def push_log(self, message: str, labels: dict[str, str], level: str = "info"):
        """
        Envia um log para o Loki.
        """
        # Timestamp atual em nanosegundos
        ts_ns = str(int(datetime.utcnow().timestamp() * 1e9))
        
        # Adiciona o nível aos labels
        labels["level"] = level
        
        payload = {
            "streams": [
                {
                    "stream": labels,
                    "values": [
                        [ts_ns, message]
                    ]
                }
            ]
        }
        
        try:
            r = requests.post(f"{self.base_url}/loki/api/v1/push", json=payload, timeout=2)
            r.raise_for_status()
        except Exception as e:
            print(f"⚠️ Falha ao enviar log para Loki: {e}")

    def query_range(self, query: str, start: datetime, end: datetime, limit: int = 1000) -> dict[str, Any]:
        params = {
            "query": query,
            "start": int(start.timestamp() * 1e9),
            "end": int(end.timestamp() * 1e9),
            "limit": limit,
            "direction": "forward",
        }
        r = requests.get(f"{self.base_url}/loki/api/v1/query_range", params=params, timeout=5)
        r.raise_for_status()
        return r.json()
