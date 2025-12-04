from __future__ import annotations
from typing import Iterable
from .scenario_runner import run_scenario


def run_multiple_scenarios(names: Iterable[str],
                           ssh_key: str | None = None) -> list[str]:
    """
    Corre vários cenários em sequência. Devolve lista de paths
    para os ficheiros JSON dos resultados.
    """
    results_paths: list[str] = []
    for name in names:
        path = run_scenario(name, ssh_key=ssh_key)
        results_paths.append(str(path))
    return results_paths
