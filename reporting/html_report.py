from __future__ import annotations
from pathlib import Path
from typing import Any
from evaluation.scoring import compute_resilience_score



def generate_html_report(experiment: dict[str, Any], out_path: Path) -> Path:
    score = compute_resilience_score(experiment)
    nodes_html = ""

    for node in experiment.get("nodes", []):
        nodes_html += f"""
        <tr>
          <td>{node.get("node_id")}</td>
          <td>{node.get("host")}</td>
          <td>{node.get("latency_before_ms")}</td>
          <td>{node.get("latency_after_ms")}</td>
          <td>{node.get("loss_before_percent")}</td>
          <td>{node.get("loss_after_percent")}</td>
        </tr>
        """

    # HTTP Probes Section
    http_html = ""
    http_before = experiment.get("http_probes", {}).get("before", [])
    http_after = experiment.get("http_probes", {}).get("after", [])
    
    # Assuming same order
    for i, res_before in enumerate(http_before):
        res_after = http_after[i] if i < len(http_after) else {}
        
        status_b = res_before.get("status") or "ERR"
        lat_b = res_before.get("latency_ms")
        status_a = res_after.get("status") or "ERR"
        lat_a = res_after.get("latency_ms")
        
        http_html += f"""
        <tr>
          <td>{res_before.get("url")}</td>
          <td>{status_b}</td>
          <td>{lat_b} ms</td>
          <td>{status_a}</td>
          <td>{lat_a} ms</td>
        </tr>
        """

    html = f"""<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Chaos Experiment {experiment.get("experiment_id")}</title>
  <style>
    body {{ font-family: sans-serif; margin: 20px; }}
    table {{ border-collapse: collapse; width: 100%; margin-bottom: 20px; }}
    th, td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
    th {{ background-color: #f2f2f2; }}
    h1 {{ color: #333; }}
  </style>
</head>
<body>
  <h1>Chaos Experiment {experiment.get("experiment_id")}</h1>
  <p>Scenario: <b>{experiment.get("scenario")}</b></p>
  <p>Score: <b>{score}</b> / 100</p>
  <p>Start: {experiment.get("start_time")}<br>
     End: {experiment.get("end_time")}</p>

  <h2>Per-node results</h2>
  <table border="1" cellpadding="4" cellspacing="0">
    <tr>
      <th>Node</th>
      <th>Host</th>
      <th>Latency before (ms)</th>
      <th>Latency after (ms)</th>
      <th>Loss before (%)</th>
      <th>Loss after (%)</th>
    </tr>
    {nodes_html}
  </table>

  <h2>HTTP Availability Probes</h2>
  <table>
    <tr>
      <th>Target</th>
      <th>Status (Before)</th>
      <th>Latency (Before)</th>
      <th>Status (After)</th>
      <th>Latency (After)</th>
    </tr>
    {http_html}
  </table>
</body>
</html>
"""
    out_path.write_text(html, encoding="utf-8")
    return out_path
