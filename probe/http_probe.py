from __future__ import annotations
import time
import requests
from dataclasses import dataclass

@dataclass
class HTTPResult:
    url: str
    status_code: int | None
    response_time_ms: float | None
    error: str | None = None

def probe_http(url: str, timeout: float = 5.0) -> HTTPResult:
    """
    Faz um request HTTP GET e mede o tempo de resposta.
    """
    start = time.time()
    try:
        resp = requests.get(url, timeout=timeout)
        duration = (time.time() - start) * 1000
        return HTTPResult(
            url=url,
            status_code=resp.status_code,
            response_time_ms=round(duration, 2)
        )
    except Exception as e:
        return HTTPResult(
            url=url,
            status_code=None,
            response_time_ms=None,
            error=str(e)
        )
