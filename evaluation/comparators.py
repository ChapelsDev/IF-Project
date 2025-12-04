from __future__ import annotations
from typing import Any
from .slis import compute_latency_delta, compute_loss_delta


def summarize_node_deltas(node_result: dict[str, Any]) -> dict[str, float | None]:
    return {
        "latency_delta_ms": compute_latency_delta(node_result),
        "loss_delta_percent": compute_loss_delta(node_result),
    }
