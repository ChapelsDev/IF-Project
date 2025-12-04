from __future__ import annotations
from dataclasses import dataclass


@dataclass
class ThroughputResult:
    target: str
    kbps: float | None


def measure_throughput_udp(target: str, port: int, duration_sec: int = 2) -> ThroughputResult:
    """
    Stub para futuro: podes implementar com iperf ou sockets.
    Por agora devolve None para não rebentar nada.
    """
    return ThroughputResult(target=f"{target}:{port}", kbps=None)
