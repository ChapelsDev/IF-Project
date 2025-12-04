from __future__ import annotations
from typing import Any


def compute_latency_delta(node_result: dict[str, Any]) -> float | None:
    before = node_result.get("latency_before_ms")
    after = node_result.get("latency_after_ms")
    if before is None or after is None:
        return None
    return after - before


def compute_loss_delta(node_result: dict[str, Any]) -> float | None:
    before = node_result.get("loss_before_percent")
    after = node_result.get("loss_after_percent")
    if before is None or after is None:
        return None
    return after - before
