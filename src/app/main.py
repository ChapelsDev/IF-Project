from fastapi import FastAPI, Request, Form, WebSocket
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse
import yaml
import os
import asyncio
import subprocess
import json
import time
import sys
from typing import List
import requests
from src.lib.chaos_ssh_driver import (
    recover_network_delay, 
    cleanup_node
)

import threading
import re
from collections import deque

app = FastAPI()

# --- Monitoramento em Background (Ping) ---
class PingMonitor:
    def __init__(self):
        self.metrics = {} # {ip: {'dup': 0.0, 'reorder': 0.0, 'window': deque(maxlen=20)}}
        self.threads = {}
        self.lock = threading.Lock()

    def start_monitoring(self, ip):
        with self.lock:
            if ip in self.threads and self.threads[ip].is_alive():
                return
            self.metrics[ip] = {'dup': 0.0, 'reorder': 0.0, 'window': deque(maxlen=50)}
            t = threading.Thread(target=self._ping_loop, args=(ip,), daemon=True)
            self.threads[ip] = t
            t.start()

    def _ping_loop(self, ip):
        # Ping rápido (0.05s intervalo) para detectar reordenação com delays menores
        # Requer que o delay da rede seja > 50ms para haver reordenação visível
        proc = subprocess.Popen(['ping', '-i', '0.05', ip], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        last_seq = -1
        
        for line in proc.stdout:
            # Parse seq
            seq_match = re.search(r'icmp_seq=(\d+)', line)
            is_dup = "(DUP!)" in line
            is_reorder = False
            
            if seq_match:
                seq = int(seq_match.group(1))
                if last_seq != -1 and seq < last_seq and not is_dup:
                    is_reorder = True
                if not is_dup: # Só atualiza seq se não for duplicado
                    last_seq = max(last_seq, seq) # Mantém o maior visto para detectar reordenação
            
            with self.lock:
                # Armazena evento na janela: (is_dup, is_reorder)
                self.metrics[ip]['window'].append((1 if is_dup else 0, 1 if is_reorder else 0))
                
                # Calcula médias
                window = self.metrics[ip]['window']
                if window:
                    total = len(window)
                    dup_count = sum(x[0] for x in window)
                    reorder_count = sum(x[1] for x in window)
                    self.metrics[ip]['dup'] = (dup_count / total) * 100
                    self.metrics[ip]['reorder'] = (reorder_count / total) * 100

    def get_metrics(self, ip):
        with self.lock:
            if ip not in self.metrics:
                return {'dup': 0.0, 'reorder': 0.0}
            return {
                'dup': self.metrics[ip]['dup'],
                'reorder': self.metrics[ip]['reorder']
            }

monitor = PingMonitor()

# Configuração de caminhos
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(BASE_DIR, "../../"))
EXPERIMENTS_DIR = os.path.join(PROJECT_ROOT, "experiments")
CONFIG_DIR = os.path.join(PROJECT_ROOT, "config")
TEMPLATES_DIR = os.path.join(BASE_DIR, "templates")

templates = Jinja2Templates(directory=TEMPLATES_DIR)

# Estado global simples para logs (em produção usaria banco de dados)
execution_logs = []
# Armazena experimentos ativos: PID -> {params}
active_experiments = {}

def load_nodes():
    nodes_path = os.path.join(CONFIG_DIR, "inventory.yaml")
    if not os.path.exists(nodes_path):
        return []
    with open(nodes_path, 'r') as f:
        try:
            data = yaml.safe_load(f)
            return data.get('nodes', []) if data else []
        except yaml.YAMLError:
            return []

def load_experiments():
    experiments = []
    if not os.path.exists(EXPERIMENTS_DIR):
        return []
    for filename in os.listdir(EXPERIMENTS_DIR):
        if filename.endswith(".json") or filename.endswith(".yaml"):
            path = os.path.join(EXPERIMENTS_DIR, filename)
            with open(path, 'r') as f:
                try:
                    content = json.load(f)
                    experiments.append({
                        "id": filename,
                        "title": content.get("title", filename),
                        "description": content.get("description", "Sem descrição")
                    })
                except:
                    continue
    return experiments

@app.get("/", response_class=HTMLResponse)
async def read_root(request: Request):
    nodes = load_nodes()
    experiments = load_experiments()
    return templates.TemplateResponse("index.html", {
        "request": request, 
        "nodes": nodes, 
        "experiments": experiments
    })

@app.get("/experiment/{experiment_id}", response_class=HTMLResponse)
async def view_experiment(request: Request, experiment_id: str):
    nodes = load_nodes()
    experiments = load_experiments()
    current_experiment = next((e for e in experiments if e['id'] == experiment_id), None)
    
    if not current_experiment:
        return HTMLResponse("Experimento não encontrado", status_code=404)

    return templates.TemplateResponse("experiment.html", {
        "request": request,
        "experiment": current_experiment,
        "all_experiments": experiments, # Passar todos os experimentos
        "nodes": nodes
    })

@app.post("/experiments/run")
async def run_experiments(
    request: Request, 
    experiment_id: List[str] = Form(...),
    node_id: List[str] = Form(...),
    latency: str = Form("200ms"),
    loss: str = Form("20%"),
    corruption: str = Form("10%"),
    duplication: str = Form("1%"),
    reordering: str = Form("5%"),
    partition_target: str = Form(""),
    size_mb: str = Form("512"),
    process_name: str = Form(""),
    disk_percent: str = Form("95"),
    rate: str = Form("1mbit"),
    burst: str = Form("32kbit"),
    duration: str = Form("30s"),
    device: str = Form("eth0"),
    ssh_user: str = Form(None),
    ssh_password: str = Form(None)
):
    nodes = load_nodes()
    # Filtrar nós selecionados
    target_nodes = [n for n in nodes if n['id'] in node_id]
    
    if not target_nodes:
        return templates.TemplateResponse("partials/log_entry.html", {
            "request": request, 
            "message": "Erro: Nenhum nó selecionado!", 
            "type": "error"
        })

    if not experiment_id:
        return templates.TemplateResponse("partials/log_entry.html", {
            "request": request, 
            "message": "Erro: Nenhum teste selecionado!", 
            "type": "error"
        })

    # Sanitize latency: ensure it has a unit (default to ms if just a number)
    if latency and latency.isdigit():
        latency = f"{latency}ms"

    # Sanitize loss: ensure it has a unit (default to % if just a number)
    if loss and loss.replace('.', '', 1).isdigit():
        loss = f"{loss}%"

    if partition_target:
        partition_target = partition_target.strip()

    started_pids = []

    for exp_id in experiment_id:
        exp_path = os.path.join(EXPERIMENTS_DIR, exp_id)
        
        for target_node in target_nodes:
            # Determinar usuário SSH (Formulário > Inventário > Default)
            final_ssh_user = ssh_user if ssh_user else target_node.get('ssh_user', 'root')
            final_ssh_password = ssh_password if ssh_password else ""

            # Passamos as variáveis customizadas para o Chaos Toolkit
            cmd = [
                "chaos", "run", exp_path,
                "--var", f"target_host={target_node['host']}",
                "--var", f"ssh_user={final_ssh_user}",
                "--var", f"ssh_password={final_ssh_password}",
                "--var", f"ssh_port={target_node.get('ssh_port', 22)}",
                "--var", f"latency={latency}",
                "--var", f"loss={loss}",
                "--var", f"corruption={corruption}",
                "--var", f"duplication={duplication}",
                "--var", f"reordering={reordering}",
                "--var", f"partition_target={partition_target}",
                "--var", f"size_mb={size_mb}",
                "--var", f"process_name={process_name}",
                "--var", f"percent={disk_percent}",
                "--var", f"rate={rate}",
                "--var", f"burst={burst}",
                "--var", f"duration={duration}",
                "--var", f"device={device}"
            ]
            
            # Adicionar PYTHONPATH para encontrar módulos customizados
            env = os.environ.copy()
            env["PYTHONPATH"] = PROJECT_ROOT
            
            # Pequeno delay para evitar race condition no 'tc' se rodar múltiplos testes simultâneos
            if len(experiment_id) > 1:
                time.sleep(2)

            # Redirecionar stdout/stderr para o console do Docker para debug
            proc = subprocess.Popen(
                cmd, stdout=sys.stdout, stderr=sys.stderr, text=True, cwd=PROJECT_ROOT, env=env
            )
            
            # Salvar contexto para permitir parada forçada e rollback
            active_experiments[proc.pid] = {
                "target_host": target_node['host'],
                "ssh_user": final_ssh_user,
                "ssh_password": final_ssh_password,
                "device": device,
                "process": proc
            }
            started_pids.append(str(proc.pid))
    
    return templates.TemplateResponse("partials/running.html", {"request": request, "pids": ",".join(started_pids)})

@app.get("/experiments/check_status")
async def check_experiments_status(request: Request, pids: str):
    pid_list = [int(p) for p in pids.split(",") if p.strip().isdigit()]
    still_running = False
    
    # Check if any of the PIDs are still in active_experiments and running
    for pid in pid_list:
        if pid in active_experiments:
            proc = active_experiments[pid]["process"]
            if proc.poll() is None: # None means still running
                still_running = True
                break
    
    if still_running:
        # Return same running html to keep polling
        return templates.TemplateResponse("partials/running.html", {"request": request, "pids": pids})
    else:
        # All finished
        # Clean up active_experiments
        for pid in pid_list:
            if pid in active_experiments:
                del active_experiments[pid]
                
        return templates.TemplateResponse("partials/finished.html", {"request": request})

@app.post("/experiment/stop")
async def stop_experiment(request: Request, pids: str = Form(...)):
    pid_list = [int(p) for p in pids.split(",") if p.strip().isdigit()]
    stopped_count = 0
    errors = []

    for pid in pid_list:
        if pid in active_experiments:
            ctx = active_experiments[pid]
            
            # 1. Matar processo do Chaos Toolkit
            try:
                ctx["process"].terminate()
                try:
                    ctx["process"].wait(timeout=2)
                except subprocess.TimeoutExpired:
                    ctx["process"].kill()
            except Exception as e:
                print(f"Erro ao matar processo {pid}: {e}")
                
            # 2. Executar rollback manualmente
            try:
                cleanup_node(
                    target_host=ctx["target_host"],
                    ssh_user=ctx["ssh_user"],
                    device=ctx["device"],
                    ssh_password=ctx["ssh_password"]
                )
                stopped_count += 1
            except Exception as e:
                errors.append(f"Falha rollback {ctx['target_host']}: {e}")
                
            del active_experiments[pid]
    
    if stopped_count > 0:
        msg = f"{stopped_count} experimento(s) interrompido(s) com sucesso."
        if errors:
            msg += f" Erros: {'; '.join(errors)}"
        return templates.TemplateResponse("partials/log_entry.html", {
            "request": request, 
            "message": msg, 
            "type": "warning"
        })
    
    return templates.TemplateResponse("partials/log_entry.html", {
        "request": request, 
        "message": "Nenhum experimento ativo encontrado para parar.", 
        "type": "error"
    })

@app.post("/run")
async def run_experiment(request: Request, node_id: str = Form(...), experiment_id: str = Form(...)):
    nodes = load_nodes()
    target_node = next((n for n in nodes if n['id'] == node_id), None)
    
    if not target_node:
        return templates.TemplateResponse("partials/log_entry.html", {
            "request": request, 
            "message": "Erro: Nó não encontrado!", 
            "type": "error"
        })

    # Construir comando do Chaos Toolkit
    # Passamos as variáveis do nó para o experimento
    exp_path = os.path.join(EXPERIMENTS_DIR, experiment_id)
    
    # Aqui assumimos que o experimento usa variáveis como target_host, ssh_user, etc.
    cmd = [
        "chaos", "run", exp_path,
        "--var", f"target_host={target_node['host']}",
        "--var", f"ssh_user={target_node['ssh_user']}",
        "--var", f"ssh_port={target_node['ssh_port']}"
    ]
    
    # Se tiver senha, passamos via env var ou config (simplificado aqui)
    # Nota: Para SSH passwordless (chaves) é mais fácil.
    
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=PROJECT_ROOT
    )
    
    return templates.TemplateResponse("partials/running.html", {"request": request, "pid": proc.pid})

@app.websocket("/ws/logs")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            # Simulação de log streaming (na prática leríamos do subprocesso)
            # Para simplificar este exemplo, apenas mantemos a conexão aberta
            await asyncio.sleep(1)
    except:
        pass

@app.get("/api/metrics/duplication")
async def get_duplication_metrics(node: str):
    # Inicia monitoramento se não existir
    monitor.start_monitoring(node)
    metrics = monitor.get_metrics(node)
    return {"value": metrics['dup']}

@app.get("/api/metrics/reordering")
async def get_reordering_metrics(node: str):
    # Inicia monitoramento se não existir
    monitor.start_monitoring(node)
    metrics = monitor.get_metrics(node)
    return {"value": metrics['reorder']}

@app.get("/api/metrics/latency")
async def get_latency_metrics(node: str):
    prometheus_url = os.getenv("PROMETHEUS_URL", "http://prometheus:9090")
    # Ajuste na query para pegar a latência ICMP do Blackbox Exporter
    # O instance geralmente é o IP alvo
    query = f'probe_duration_seconds{{instance="{node}"}}'
    try:
        response = requests.get(f"{prometheus_url}/api/v1/query", params={"query": query})
        data = response.json()
        if data["status"] == "success" and data["data"]["result"]:
            # Prometheus retorna [timestamp, value]
            timestamp = data["data"]["result"][0]["value"][0]
            value = float(data["data"]["result"][0]["value"][1])
            return {"timestamp": timestamp, "value": value}
        return {"value": 0} # Retorna 0 se não houver dados (timeout ou down)
    except Exception as e:
        print(f"Erro ao consultar Prometheus: {e}")
        return {"value": 0}

@app.get("/api/metrics/packet_loss")
async def get_packet_loss_metrics(node: str):
    prometheus_url = os.getenv("PROMETHEUS_URL", "http://prometheus:9090")
    # Calcula a taxa de falha nos últimos 10 segundos (com scrape de 1s, temos 10 amostras)
    # Isso torna o gráfico mais responsivo
    query = f'(1 - avg_over_time(probe_success{{instance="{node}"}}[10s])) * 100'
    try:
        response = requests.get(f"{prometheus_url}/api/v1/query", params={"query": query})
        data = response.json()
        if data["status"] == "success" and data["data"]["result"]:
            value = float(data["data"]["result"][0]["value"][1])
            return {"value": value}
        return {"value": 0}
    except Exception as e:
        print(f"Erro ao consultar Prometheus: {e}")
        return {"value": 0}

@app.get("/api/metrics/throughput")
async def get_throughput_metrics(node: str):
    prometheus_url = os.getenv("PROMETHEUS_URL", "http://prometheus:9090")
    # Taxa de transmissão (Tx) em bits/s nos últimos 30s
    # Filtramos por device!='lo' para ignorar loopback
    # O instance no node_exporter geralmente é IP:9100
    query = f'sum(rate(node_network_transmit_bytes_total{{instance=~"{node}:.*", device!="lo"}}[30s])) * 8'
    try:
        response = requests.get(f"{prometheus_url}/api/v1/query", params={"query": query})
        data = response.json()
        if data["status"] == "success" and data["data"]["result"]:
            value = float(data["data"]["result"][0]["value"][1])
            return {"value": value}
        return {"value": 0}
    except Exception as e:
        print(f"Erro ao consultar Prometheus: {e}")
        return {"value": 0}

@app.get("/api/metrics/cpu")
async def get_cpu_metrics(node: str):
    prometheus_url = os.getenv("PROMETHEUS_URL", "http://prometheus:9090")
    # CPU Usage %: 100 - idle
    query = f'100 - (avg by (instance) (irate(node_cpu_seconds_total{{mode="idle", instance=~"{node}:.*"}}[1m])) * 100)'
    try:
        response = requests.get(f"{prometheus_url}/api/v1/query", params={"query": query})
        data = response.json()
        if data["status"] == "success" and data["data"]["result"]:
            value = float(data["data"]["result"][0]["value"][1])
            return {"value": value}
        return {"value": 0}
    except Exception as e:
        print(f"Erro ao consultar Prometheus: {e}")
        return {"value": 0}

@app.get("/api/metrics/memory")
async def get_memory_metrics(node: str):
    prometheus_url = os.getenv("PROMETHEUS_URL", "http://prometheus:9090")
    # Memory Usage %: (Total - Available) / Total * 100
    query = f'(1 - (node_memory_MemAvailable_bytes{{instance=~"{node}:.*"}} / node_memory_MemTotal_bytes{{instance=~"{node}:.*"}})) * 100'
    try:
        response = requests.get(f"{prometheus_url}/api/v1/query", params={"query": query})
        data = response.json()
        if data["status"] == "success" and data["data"]["result"]:
            value = float(data["data"]["result"][0]["value"][1])
            return {"value": value}
        return {"value": 0}
    except Exception as e:
        print(f"Erro ao consultar Prometheus: {e}")
        return {"value": 0}

@app.get("/api/metrics/disk")
async def get_disk_metrics(node: str):
    prometheus_url = os.getenv("PROMETHEUS_URL", "http://prometheus:9090")
    # Disk Usage % for root partition
    query = f'100 - (node_filesystem_avail_bytes{{instance=~"{node}:.*", mountpoint="/"}} / node_filesystem_size_bytes{{instance=~"{node}:.*", mountpoint="/"}} * 100)'
    try:
        response = requests.get(f"{prometheus_url}/api/v1/query", params={"query": query})
        data = response.json()
        if data["status"] == "success" and data["data"]["result"]:
            value = float(data["data"]["result"][0]["value"][1])
            return {"value": value}
        return {"value": 0}
    except Exception as e:
        print(f"Erro ao consultar Prometheus: {e}")
        return {"value": 0}
