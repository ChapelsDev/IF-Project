from __future__ import annotations
from typing import Any
from pathlib import Path
import matplotlib.pyplot as plt


def plot_latency_bar(experiment: dict[str, Any], out_path: Path) -> Path:
    labels = []
    icmp_before = []
    icmp_after = []
    http_before = []
    http_after = []

    has_http = False

    for node in experiment.get("nodes", []):
        labels.append(node.get("node_id"))
        icmp_before.append(node.get("latency_before_ms") or 0.0)
        icmp_after.append(node.get("latency_after_ms") or 0.0)
        
        hb = node.get("http_latency_before_ms") or 0.0
        ha = node.get("http_latency_after_ms") or 0.0
        http_before.append(hb)
        http_after.append(ha)
        if hb > 0 or ha > 0:
            has_http = True

    x = range(len(labels))
    plt.figure(figsize=(10, 6))
    
    width = 0.2
    
    # ICMP bars
    plt.bar([i - width for i in x], icmp_before, width=width, label="ICMP Before", color='lightblue')
    plt.bar([i for i in x], icmp_after, width=width, label="ICMP After", color='blue')
    
    if has_http:
        plt.bar([i + width for i in x], http_before, width=width, label="HTTP Before", color='lightgreen')
        plt.bar([i + width*2 for i in x], http_after, width=width, label="HTTP After", color='green')
        
    plt.xticks([i + width/2 for i in x], labels, rotation=45)
    plt.ylabel("Latency (ms)")
    plt.title(f"Latency Analysis: {experiment.get('scenario', 'Unknown')}")
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_path)
    plt.close()
    return out_path
