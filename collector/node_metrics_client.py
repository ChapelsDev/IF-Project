from __future__ import annotations
from dataclasses import dataclass
import requests


@dataclass
class NodeMetrics:
    node_id: str
    role: str
    raw: dict


def fetch_node_metrics(url: str, timeout: int = 10) -> NodeMetrics:
    resp = requests.get(url, timeout=timeout)
    resp.raise_for_status()
    data = resp.json()
    return NodeMetrics(
        node_id=data.get("node_id", "unknown"),
        role=data.get("role", "unknown"),
        raw=data,
    )
