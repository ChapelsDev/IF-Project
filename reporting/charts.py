from __future__ import annotations
from typing import Any
from pathlib import Path
import matplotlib.pyplot as plt


def plot_latency_bar(experiment: dict[str, Any], out_path: Path) -> Path:
    labels = []
    before_vals = []
    after_vals = []

    for node in experiment.get("nodes", []):
        labels.append(node.get("node_id"))
        before_vals.append(node.get("latency_before_ms") or 0.0)
        after_vals.append(node.get("latency_after_ms") or 0.0)

    x = range(len(labels))
    plt.figure()
    plt.bar(x, before_vals, width=0.4, label="before")
    plt.bar([i + 0.4 for i in x], after_vals, width=0.4, label="after")
    plt.xticks([i + 0.2 for i in x], labels, rotation=45)
    plt.ylabel("Latency (ms)")
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_path)
    plt.close()
    return out_path
