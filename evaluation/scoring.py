from __future__ import annotations
from typing import Any


def compute_resilience_score(experiment: dict[str, Any]) -> float:
    """
    Score muito simples:
      100 = perfeito, vai descendo com aumento de latência/perda.
    Só para ter algo a mostrar; podes sofisticar depois.
    """
    base = 100.0
    penalty = 0.0

    for node in experiment.get("nodes", []):
        lat_before = node.get("latency_before_ms") or 0.0
        lat_after = node.get("latency_after_ms") or lat_before
        loss_after = node.get("loss_after_percent") or 0.0

        extra_lat = max(0.0, lat_after - lat_before)
        penalty += extra_lat * 0.1   # 0.1 ponto por ms extra
        penalty += loss_after * 0.5  # 0.5 ponto por % de perda

    score = max(0.0, base - penalty)
    return round(score, 2)
