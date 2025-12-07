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



Monitorização & Observabilidade
Grafana: http://localhost:3000 (Dashboards e Visualização)
Login: admin / admin (ou a senha que definiu)
Prometheus: http://localhost:9090 (Coleta de Métricas e Alertas)
Consul UI: http://localhost:8500 (Estado do Cluster e Serviços)
🛠️ Infraestrutura (Nós do Cluster)
Consul Server 1: 172.21.0.2 (Líder/Server)
Consul Server 2: 172.21.0.3 (Server)
Consul Server 3: 172.21.0.4 (Server)
🔍 Métricas (Raw Data)
Node Exporter (Server 1): http://172.21.0.2:9100/metrics
Node Exporter (Server 2): http://172.21.0.3:9100/metrics
Node Exporter (Server 3): http://172.21.0.4:9100/metrics
Chat App (Mock): http://172.21.0.X:5000/metrics (Onde X é o IP do nó onde está a correr)
📂 Logs & Relatórios (Locais)
Relatórios HTML: logs/*.html (Gerados após os testes de caos)
Logs JSON: logs/*.json (Dados brutos dos testes)