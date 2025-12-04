from __future__ import annotations
import subprocess
import re
import os
from dataclasses import dataclass


@dataclass
class LatencyResult:
    target: str
    avg_ms: float | None
    loss_percent: float | None


# Versão em inglês (forçada via LC_ALL=C)
PING_STATS_RE = re.compile(
    r"(?P<tx>\d+) packets transmitted, (?P<rx>\d+) received, .*?(?P<loss>[\d\.]+)% packet loss",
    re.DOTALL,
)
RTT_RE = re.compile(
    r"rtt min/avg/max/mdev = (?P<min>[\d\.]+)/(?P<avg>[\d\.]+)/(?P<max>[\d\.]+)/"
)

# Fallback: apanhar time=XX ms de cada linha
TIME_RE = re.compile(r"time=([\d\.]+)\s*ms")


def measure_latency(target: str, count: int = 3, timeout: int = 1) -> LatencyResult:
    """
    Mede latência usando ping -c N <target>.
    Tenta forçar LC_ALL=C para ter saída em inglês.
    Se mesmo assim falhar, tenta extrair time=XX ms das linhas.
    """
    env = os.environ.copy()
    env["LC_ALL"] = "C"  # força saída em inglês

    proc = subprocess.run(
        ["ping", "-c", str(count), "-W", str(timeout), target],
        capture_output=True,
        text=True,
        env=env,
    )
    out = proc.stdout

    loss: float | None = None
    avg: float | None = None

    # 1) Tentativa "normal": usar as linhas de estatísticas em inglês
    m_stats = PING_STATS_RE.search(out)
    if m_stats:
        loss = float(m_stats.group("loss"))

    m_rtt = RTT_RE.search(out)
    if m_rtt:
        avg = float(m_rtt.group("avg"))

    # 2) Fallback: se não apanhou nada, extrair time=XX ms e fazer média
    if avg is None:
        times: list[float] = []
        for line in out.splitlines():
            m = TIME_RE.search(line)
            if m:
                times.append(float(m.group(1)))
        if times:
            avg = sum(times) / len(times)

    # 3) Se não apanhou loss, mas temos tx/rx, podemos derivar (opcional)

    return LatencyResult(target=target, avg_ms=avg, loss_percent=loss)
