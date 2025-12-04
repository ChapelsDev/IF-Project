from __future__ import annotations
import requests
from datetime import datetime
from typing import Any


class PrometheusClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def query(self, expression: str, ts: datetime | None = None) -> dict[str, Any]:
        params = {"query": expression}
        if ts is not None:
            params["time"] = ts.timestamp()
        r = requests.get(f"{self.base_url}/api/v1/query", params=params, timeout=5)
        r.raise_for_status()
        return r.json()

    def query_range(self, expression: str, start: datetime, end: datetime, step: str = "5s") -> dict[str, Any]:
        params = {
            "query": expression,
            "start": start.timestamp(),
            "end": end.timestamp(),
            "step": step,
        }
        r = requests.get(f"{self.base_url}/api/v1/query_range", params=params, timeout=5)
        r.raise_for_status()
        return r.json()
