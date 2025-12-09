from __future__ import annotations
from .ssh_executor import SSHExecutor


def _ensure_tc(executor: SSHExecutor):
    """Verifica se o tc está instalado e tenta instalar se não estiver (Alpine)."""
    code, _, _ = executor.run("which tc")
    if code != 0:
        print("⚠️ 'tc' não encontrado. Tentando instalar iproute2 (Alpine)...")
        # Tenta instalar sem sudo (assumindo root) ou com sudo se falhar
        executor.run("apk add iproute2 || sudo apk add iproute2")

def apply_netem(executor: SSHExecutor,
                interface: str,
                delay_ms: int = 0,
                jitter_ms: int = 0,
                loss_percent: int = 0) -> tuple[int, str, str]:
    """
    Aplica um perfil netem simples (delay+jitter+loss).
    """
    _ensure_tc(executor)

    parts: list[str] = []
    if delay_ms or jitter_ms:
        if jitter_ms:
            parts.append(f"delay {delay_ms}ms {jitter_ms}ms")
        else:
            parts.append(f"delay {delay_ms}ms")
    if loss_percent:
        parts.append(f"loss {loss_percent}%")

    args = " ".join(parts) if parts else "delay 0ms"
    
    # Remove sudo (assumindo root)
    # Garante estado limpo antes de adicionar
    executor.run(f"tc qdisc del dev {interface} root || true")
    
    # Usa 'add' em vez de 'replace' para evitar erros se não existir qdisc
    cmd = f"tc qdisc add dev {interface} root netem {args}"
    return executor.run(cmd)


def clear_netem(executor: SSHExecutor, interface: str) -> tuple[int, str, str]:
    """
    Remove qdisc root (ignora erro se não existir).
    """
    cmd = f"tc qdisc del dev {interface} root || true"
    return executor.run(cmd)
