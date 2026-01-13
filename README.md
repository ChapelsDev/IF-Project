# Chaos Engineering Platform

Plataforma completa para injeção de falhas e observabilidade em sistemas distribuídos. Este projeto permite orquestrar ataques de Chaos Engineering (latência de rede, falhas de processo, etc.) em máquinas remotas e visualizar o impacto em tempo real.

## ✨ Funcionalidades Principais

- **Execução em Massa:** Selecione múltiplos nós e múltiplos experimentos para execução simultânea.
- **Controle Total:** Botão de "Parar Todos" para interromper imediatamente todos os ataques e reverter o estado da rede.
- **Visualização Inteligente:** Gráficos em tempo real para Latência, Perda de Pacotes, Largura de Banda, Duplicação e Reordenação.
- **Driver SSH Personalizado:** Injeção de falhas via SSH usando `tc` (Traffic Control) sem necessidade de agentes pesados.
- **Monitoramento Avançado:** Detecção de anomalias de rede complexas (Duplicação e Reordenação) via análise ativa de ICMP.

## 🧪 Experimentos Suportados

A plataforma suporta uma ampla gama de injeções de falhas, divididas em categorias:

### 🌐 Falhas de Rede (Network)
1.  **Network Delay (Latência):** Adiciona atraso na interface de rede.
2.  **Packet Loss (Perda):** Descarta pacotes aleatoriamente.
3.  **Bandwidth Limit (Largura de Banda):** Restringe a taxa de upload/download (TBF).
4.  **Packet Duplication (Duplicação):** Duplica uma porcentagem dos pacotes enviados.
5.  **Packet Reordering (Reordenação):** Altera a ordem de entrega dos pacotes.
6.  **Packet Corruption (Corrupção):** Introduz erros em bits aleatórios dos pacotes.
7.  **Network Partition (Partição de Rede):** Isola o nó de um IP específico (Blackhole).

### 💻 Falhas de Recursos (Resource)
8.  **CPU Stress:** Consome 100% de todos os núcleos da CPU usando scripts Python multiprocessados.
9.  **Memory Stress:** Aloca e retém uma quantidade específica de memória RAM (ex: 512MB).
10. **Disk Fill (Enchimento de Disco):** Preenche a partição raiz até atingir uma porcentagem alvo (ex: 95%) usando `fallocate` ou escrita direta.

### ⚙️ Falhas de Processo (State)
11. **Process Killer:** Encerra forçadamente (`SIGKILL`) processos específicos pelo nome (ex: `consul`, `nginx`).

## 🛠️ Validação e Testes Realizados

Para garantir a robustez da plataforma, as novas funcionalidades foram validadas com os seguintes cenários:

| Funcionalidade | Cenário de Teste | Resultado Esperado | Status |
| :--- | :--- | :--- | :--- |
| **Process Killer** | Iniciar `sleep 1000` no alvo e executar ataque "Process Killer" com nome `sleep`. | O processo deve desaparecer da lista `ps aux` imediatamente. | ✅ Aprovado |
| **Disk Fill** | Configurar ataque para 50% de disco. | O gráfico de "Uso de Disco" na UI deve subir para 50% e o arquivo `/chaos_disk_fill` deve ser criado no alvo. | ✅ Aprovado |
| **CPU Stress** | Executar ataque de CPU por 30s. | O uso de CPU no `htop` do alvo deve atingir 100% em todos os cores. | ✅ Aprovado |
| **Stop/Rollback** | Interromper ataque de Disco e CPU no meio da execução. | O arquivo temporário deve ser removido e os processos Python de estresse devem ser mortos imediatamente. | ✅ Aprovado |
| **Resiliência** | Tentar matar serviços resilientes (ex: Consul). | O processo morre, mas o Systemd o reinicia (comportamento correto de HA). | ✅ Validado |

## 🏗 Arquitetura

O sistema é dividido em **Control Plane** (sua máquina) e **Data Plane** (máquinas alvo).

### Control Plane (Docker)
- **Chaos UI (http://localhost:8000):** Interface web moderna para selecionar alvos e disparar experimentos.
- **Chaos Toolkit:** Engine de execução dos experimentos.
- **Prometheus:** Coleta de métricas.
- **Grafana (http://localhost:3000):** Visualização de métricas e logs.
- **Loki:** Agregação de logs.

### Data Plane (Máquinas Remotas)
- **Serviços Alvo:** Seus serviços (Consul, SeaweedFS, etc.).
- **Promtail:** Agente leve que envia logs locais para o Loki.
- **SSH:** O Chaos Toolkit conecta via SSH para injetar falhas (sem necessidade de agente pesado de chaos).

## 🚀 Como Iniciar

### 1. Pré-requisitos
- Docker & Docker Compose
- Python 3.10+
- Acesso SSH às máquinas alvo

### 2. Subir o Control Plane
Inicie a stack de observabilidade e a interface de controle:

```bash
docker-compose up -d --build
```

Acesse:
- **UI de Controle:** [http://localhost:8000](http://localhost:8000)
- **Grafana:** [http://localhost:3000](http://localhost:3000) (Login: `admin` / `admin`)

### 3. Configurar Máquinas Alvo (Data Plane)
Instale o agente de logs (Promtail) nas máquinas que você deseja monitorar:

```bash
pip install -r requirements.txt
python3 scripts/deploy_agent.py
```
*Siga as instruções interativas para fornecer IP e credenciais SSH.*

### 4. Configurar Alvos
Edite o arquivo `config/inventory.yaml` para registrar suas máquinas. A UI lê este arquivo para listar os alvos disponíveis.

```yaml
nodes:
  - id: server1
    host: 192.168.1.10
    ssh_user: root
    ssh_port: 22
    # ...
```

## ⚡ Executando um Experimento

1. Abra a **Chaos UI** em [http://localhost:8000](http://localhost:8000).
2. Selecione um ou mais **Nós Alvo** na lista (checkboxes).
3. Escolha um ou mais **Experimentos** (ex: `network_delay`).
4. Clique em **INICIAR ATAQUE**.
5. Acompanhe o gráfico em tempo real. Segmentos da linha ficarão vermelhos se a latência subir drasticamente (> 100ms).
6. Use o botão **PARAR TODOS** para interromper os testes a qualquer momento e reverter as falhas.

## 📂 Estrutura do Projeto

```
.
├── config/                 # Configurações (Prometheus, Loki, Grafana, Nodes)
├── experiments/            # Definições dos experimentos (JSON/YAML)
├── scripts/                # Scripts auxiliares (deploy, run manual)
├── src/
│   ├── app/                # Aplicação Web (FastAPI)
│   │   └── templates/      # Templates HTML (Jinja2 + HTMX)
│   └── lib/                # Drivers e utilitários (SSH Driver)
├── docker-compose.yml      # Definição da stack completa
└── requirements.txt        # Dependências Python
```

## 🛠 Desenvolvimento

Para adicionar novos experimentos, basta criar arquivos `.json` ou `.yaml` na pasta `experiments/`. A UI irá detectá-los automaticamente.


sudo tc qdisc del dev enp3s0 root