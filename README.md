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

## Como usar (Legacy Python Script)

```bash
pip install -r requirements.txt

python3 main.py run --scenario network_delay --ssh-key ~/.ssh/id_rsa
```

## 🚀 Setup Chaos Mesh (Novo Sistema)

Este projeto migrou para usar **Chaos Mesh** sobre Kubernetes (Minikube) para orquestrar ataques, inclusive em máquinas remotas.

### 1. Pré-requisitos
- **Minikube** instalado e a correr.
- **Helm** e **Kubectl** instalados.
- Acesso SSH à máquina alvo (`192.168.1.196`).

### 2. Iniciar o Control Plane (Local)
Inicia o cluster local onde corre o Chaos Mesh:
```bash
minikube start
```

Abre o túnel para aceder ao Dashboard:
```bash
# Deixa este terminal aberto
kubectl port-forward -n chaos-mesh svc/chaos-dashboard 2333:2333
```
Acede a: [http://localhost:2333](http://localhost:2333)

### 3. Obter Token de Acesso
Para fazer login no Dashboard, gera um token:
```bash
kubectl create token account-cluster-manager-sa
```

### 4. Configurar Agente Remoto (Target)
Para atacar a máquina remota (`192.168.1.196`) ou os seus containers:

1. Executa o script de instalação automática:
   ```bash
   ./install_remote_chaosd.sh
   ```
   *Isto instala o `chaosd` no servidor remoto e regista-o no teu Chaos Mesh local.*

2. O script vai devolver o **PID** do container `server1`. Guarda este número!

### 5. Criar um Ataque
1. No Dashboard, vai a **New Experiment** > **Physical Machine**.
2. Escolhe o tipo de ataque (ex: **Process Attack** para matar containers, ou **Network Attack** para latência).
3. No campo "Process ID", usa o PID obtido no passo anterior.
4. Submete o ataque.

---

## Monitorização & Observabilidade
- **Grafana**: http://localhost:3000 (Dashboards e Visualização)
  - Login: admin / admin
- **Prometheus**: http://localhost:9090
- **Consul UI**: http://localhost:8500

## Infraestrutura (Nós do Cluster)
- Consul Server 1: 172.21.0.2
- Consul Server 2: 172.21.0.3
- Consul Server 3: 172.21.0.4



