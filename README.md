IF Project
# Chaos / Evaluation System

MVP de um sistema de Chaos Engineering em Python.

## Estrutura

- `chaos_manager/` — aplica caos via SSH + tc netem e corre cenários.
- `probe/` — probes ativos (latência, etc.).
- `collector/` — recolha de métricas dos nós e de Prometheus/Loki (futuro).
- `evaluation/` — cálculo de SLI/SLO e resilience score.
- `reporting/` — geração de relatórios HTML e gráficos.
- `config/` — configuração de nós, cenários e probes.
- `logs/` — saída de logs e resultados dos experimentos.

## Como usar

```bash
pip install -r requirements.txt

python3 main.py run --scenario network_delay --ssh-key ~/.ssh/id_rsa
