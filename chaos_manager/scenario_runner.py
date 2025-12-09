from __future__ import annotations
import json
import time
import os
from datetime import datetime
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List
from concurrent.futures import ThreadPoolExecutor, as_completed

import yaml

from .ssh_executor import SSHExecutor, NodeSSHConfig
from .netem_profiles import apply_netem, clear_netem
from .consul_observer import wait_for_node_removal, get_consul_nodes
from probe.latency_probe import measure_latency
from probe.http_probe import probe_http
from collector.node_metrics_client import fetch_node_metrics
from collector.prometheus_client import PrometheusClient
from collector.loki_client import LokiClient
from collector.otel_collector import setup_telemetry
import re

# Configuração de Telemetria
tracer = setup_telemetry("chaos-manager")
loki = LokiClient("http://loki:3100")



ROOT_DIR = Path(__file__).resolve().parents[1]
CONFIG_DIR = ROOT_DIR / "config"


def measure_remote_latency(executor: SSHExecutor, target: str = "8.8.8.8", count: int = 4) -> tuple[float, float]:
    """
    Executa ping DENTRO do container para um alvo externo.
    Retorna (latencia_media_ms, perda_pacotes_percent).
    """
    # Tenta ping padrão (iputils) ou busybox ping
    cmd = f"ping -c {count} -W 2 {target}"
    exit_code, out, err = executor.run(cmd)
    
    if exit_code != 0:
        # Fallback para busybox ping
        cmd = f"ping -c {count} {target}"
        exit_code, out, err = executor.run(cmd)
        if exit_code != 0:
            print(f"DEBUG: Ping falhou no remote: {err}")
            return 0.0, 100.0 # 100% de perda se falhar tudo

    # Parse Latency
    lat = 0.0
    match = re.search(r"(?:rtt|round-trip) min/avg/max(?:/mdev)? = [\d\.]+/([\d\.]+)/", out)
    if match:
        lat = float(match.group(1))
    
    # Parse Loss
    # "4 packets transmitted, 4 received, 0% packet loss"
    loss = 0.0
    loss_match = re.search(r"(\d+)% packet loss", out)
    if loss_match:
        loss = float(loss_match.group(1))

    return lat, loss
LOGS_DIR = ROOT_DIR / "logs"


@dataclass
class ScenarioConfig:
    name: str
    description: str
    duration_sec: int
    netem: Dict[str, Any]


def _load_yaml(path: Path) -> Dict[str, Any]:
    with path.open() as f:
        return yaml.safe_load(f)


def load_scenario(name: str) -> ScenarioConfig:
    """
    Carrega um cenário do ficheiro scenarios.yaml.

    Suporta dois formatos de YAML:

      1) Com chave de topo 'scenarios':
         scenarios:
           network_delay: { ... }

      2) Diretamente os cenários na raiz:
         network_delay: { ... }
    """
    raw = _load_yaml(CONFIG_DIR / "scenarios.yaml")

    # Aceita os dois formatos
    if "scenarios" in raw:
        data = raw["scenarios"]
    else:
        data = raw

    if name not in data:
        raise KeyError(f"Scenario '{name}' not found in scenarios.yaml")

    s = data[name]
    return ScenarioConfig(
        name=name,
        description=s.get("description", ""),
        duration_sec=int(s.get("duration_sec", 30)),
        netem=s.get("netem", {}),
    )


def load_nodes() -> List[Dict[str, Any]]:
    data = _load_yaml(CONFIG_DIR / "nodes.yaml")
    return data["nodes"]


from urllib.parse import urlparse

def fetch_metrics_unified(node: Dict[str, Any]) -> Dict[str, Any]:
    """
    Obtém métricas via Prometheus (se configurado) ou direto do nó (legacy).
    """
    settings = {}
    if (CONFIG_DIR / "settings.yaml").exists():
        settings = _load_yaml(CONFIG_DIR / "settings.yaml")
    
    prom_url = settings.get("prometheus_url")
    
    if prom_url:
        try:
            client = PrometheusClient(prom_url)
            
            # Extrair instance (host:port) da URL de métricas
            # Ex: http://192.168.1.196:9100/metrics -> 192.168.1.196:9100
            parsed = urlparse(node["metrics_url"])
            instance_label = parsed.netloc
            
            # Queries padrão para Node Exporter filtrando por instance
            # CPU: 100 - (idle %)
            cpu_query = f'100 - (avg by(instance) (rate(node_cpu_seconds_total{{mode="idle", instance="{instance_label}"}}[1m])) * 100)'
            # RAM: Usada %
            mem_query = f'100 * (1 - ((node_memory_MemFree_bytes{{instance="{instance_label}"}} + node_memory_Buffers_bytes{{instance="{instance_label}"}} + node_memory_Cached_bytes{{instance="{instance_label}"}}) / node_memory_MemTotal_bytes{{instance="{instance_label}"}}))'
            # Rede: Bytes recebidos por segundo (na interface principal)
            net_rx_query = f'rate(node_network_receive_bytes_total{{device!="lo", instance="{instance_label}"}}[1m])'

            cpu_data = client.query(cpu_query)
            mem_data = client.query(mem_query)
            net_data = client.query(net_rx_query)
            
            cpu_val = 0.0
            if cpu_data.get("data", {}).get("result"):
                cpu_val = float(cpu_data["data"]["result"][0]["value"][1])
                
            mem_val = 0.0
            if mem_data.get("data", {}).get("result"):
                mem_val = float(mem_data["data"]["result"][0]["value"][1])

            net_rx_val = 0.0
            if net_data.get("data", {}).get("result"):
                # Pega o primeiro resultado (pode haver várias interfaces, simplificando para a primeira não-lo)
                net_rx_val = float(net_data["data"]["result"][0]["value"][1])
                
            return {
                "source": "prometheus",
                "cpu": cpu_val,
                "memory_percent": mem_val,
                "net_rx_bytes_sec": net_rx_val
            }
        except Exception as e:
            return {"error": f"Prometheus error: {e}"}
    else:
        # Legacy: fetch direto JSON
        try:
            m = fetch_node_metrics(node["metrics_url"])
            return m.raw
        except Exception as e:
            return {"error": str(e)}


def run_scenario(scenario_name: str,
                 ssh_key: str | None = None,
                 sudo_password: str | None = None,
                 scenario_override: ScenarioConfig | None = None,
                 target_node: str | None = None) -> Path:
    
    # Inicia um Trace para o cenário
    with tracer.start_as_current_span("run_scenario") as span:
        span.set_attribute("scenario.name", scenario_name)
        if target_node:
            span.set_attribute("scenario.target", target_node)
            
        loki.push_log(f"Iniciando cenário de caos: {scenario_name}", {"job": "chaos_manager", "scenario": scenario_name})

        LOGS_DIR.mkdir(exist_ok=True, parents=True)

        # Expande "~" se vier algo tipo "~/.ssh/chaos_local"
        expanded_key: str | None = None
        if ssh_key:
            expanded_key = str(Path(ssh_key).expanduser())

        if scenario_override:
            scenario = scenario_override
        else:
            scenario = load_scenario(scenario_name)
        
        nodes_cfg = load_nodes()

        # Sincronizar IPs com Consul (Resolução Dinâmica)
        consul_nodes_list = get_consul_nodes()
        # Converte lista para dicionário {NodeName: Address}
        consul_map = {n["Node"]: n["Address"] for n in consul_nodes_list}
        
        if consul_map:
            updated_count = 0
            for node in nodes_cfg:
                node_id = node.get("id")
                if node_id in consul_map:
                    current_ip = node.get("host")
                    new_ip = consul_map[node_id]
                    # Só atualiza se o IP for diferente E não for um IP interno de container (172.x)
                    # para não estragar a config de acesso remoto
                    if current_ip != new_ip and not new_ip.startswith("172."):
                        print(f"SYNC: Atualizando IP do nó '{node_id}': {current_ip} -> {new_ip}")
                        node["host"] = new_ip
                        updated_count += 1
            if updated_count > 0:
                loki.push_log(f"Sincronizados {updated_count} IPs com o Consul.", {"job": "chaos_manager"})

        probes_cfg = _load_yaml(CONFIG_DIR / "probes.yaml")

        experiment_id = datetime.utcnow().strftime(f"{scenario.name}-%Y%m%d-%H%M%S")

        experiment: Dict[str, Any] = {
            "experiment_id": experiment_id,
            "scenario": scenario.name,
            "description": scenario.description,
            "start_time": datetime.utcnow().isoformat() + "Z",
            "nodes": [],
            "http_probes": {"before": [], "after": []}
        }

        # 0) Preparar executores e limpar caos residual
        with tracer.start_as_current_span("setup_connections"):
            executors: List[tuple[Dict[str, Any], SSHExecutor]] = []
            
            # Processar lista de alvos (suporta vírgula: "worker-01,worker-02")
            target_list = []
            if target_node:
                target_list = [t.strip() for t in target_node.split(",") if t.strip()]

            for node in nodes_cfg:
                # Se target_node for especificado, ignora nodes que não estão na lista
                if target_list:
                    if node["id"] not in target_list and node["host"] not in target_list:
                        continue

                # Prioridade: 1. Argumento (UI), 2. Config YAML, 3. Variável de Ambiente
                s_pass = sudo_password or node.get("sudo_password") or os.environ.get("CHAOS_SUDO_PASSWORD")

                cfg = NodeSSHConfig(
                    host=node["host"],
                    user=node["ssh_user"],
                    port=node.get("ssh_port", 22),
                    sudo_password=s_pass,
                    password=node.get("ssh_password")
                )
                ex = SSHExecutor(cfg, key_path=expanded_key)
                executors.append((node, ex))
                
                # Limpeza preventiva
                clear_netem(ex, node["net_if"])
            
            # Pequena pausa para estabilizar rede
            time.sleep(1)

        # 1) medir antes
        with tracer.start_as_current_span("measure_baseline"):
            for node in nodes_cfg:
                # Se target_node for especificado, ignora nodes que não estão na lista
                if target_list:
                    if node["id"] not in target_list and node["host"] not in target_list:
                        continue

                # 1) medir antes
                # lat_res = measure_latency(node["host"])  <-- Medição antiga (Host)
                
                # Nova medição: Ping de dentro do container para fora
                lat_avg, loss_avg = measure_remote_latency(ex, target="8.8.8.8")
                if lat_avg == 0.0 and loss_avg == 100.0:
                     # Tenta gateway/host se internet falhar
                     lat_avg, loss_avg = measure_remote_latency(ex, target="192.168.1.196")

                # Medir latência HTTP ao agente (reflete o delay dentro do container)
                http_lat = 0.0
                if "metrics_url" in node:
                    res = probe_http(node["metrics_url"])
                    if res.response_time_ms:
                        http_lat = res.response_time_ms

                metrics_raw = fetch_metrics_unified(node)

                experiment["nodes"].append({
                    "node_id": node["id"],
                    "host": node["host"],
                    "latency_before_ms": lat_avg,
                    "http_latency_before_ms": http_lat,
                    "loss_before_percent": loss_avg,
                    "metrics_before": metrics_raw,
                })

            # 1.1) HTTP Probes (Before)
            if probes_cfg.get("scenarios", {}).get("default", {}).get("http", False):
                targets = probes_cfg.get("http_targets", [])
                for url in targets:
                    res = probe_http(url)
                    experiment["http_probes"]["before"].append({
                        "url": res.url,
                        "status": res.status_code,
                        "latency_ms": res.response_time_ms,
                        "error": res.error
                    })

        # 2) aplicar caos
        with tracer.start_as_current_span("inject_chaos"):
            for node, ex in executors:
                exit_code, out, err = apply_netem(
                    ex,
                    interface=node["net_if"],
                    delay_ms=int(scenario.netem.get("delay_ms", 0)),
                    jitter_ms=int(scenario.netem.get("jitter_ms", 0)),
                    loss_percent=int(scenario.netem.get("loss_percent", 0)),
                )
                if exit_code != 0:
                    print(f"ERRO ao aplicar netem no node {node['id']}: {err}")
                    print(f"Output: {out}")
                else:
                    # Debug: Verificar se a regra foi aplicada
                    _, qdisc_out, _ = ex.run(f"tc qdisc show dev {node['net_if']}")
                    print(f"DEBUG: Regras TC em {node['id']}:\n{qdisc_out}")

        # 3) espera
        with tracer.start_as_current_span("wait_duration"):
            loki.push_log(f"Caos aplicado. Aguardando {scenario.duration_sec}s...", {"job": "chaos_manager", "scenario": scenario_name})
            
            loss_percent = int(scenario.netem.get("loss_percent", 0))
            if loss_percent == 100:
                loki.push_log("Perda de 100% detectada. Iniciando Watcher do Consul...", {"job": "chaos_manager"})
                
                def watch_node(node_info):
                    # Assume service name is 'consul' (default for agents) or configured
                    service_name = node_info.get("consul_service", "consul")
                    node_id = node_info.get("id")
                    return wait_for_node_removal(service_name, node_id, timeout=scenario.duration_sec)

                with ThreadPoolExecutor(max_workers=len(executors)) as executor:
                    future_to_node = {executor.submit(watch_node, n): n for n, _ in executors}
                    
                    for future in as_completed(future_to_node):
                        node_ref = future_to_node[future]
                        try:
                            removed = future.result()
                            if removed:
                                loki.push_log(f"Watcher: Nó {node_ref['id']} removido do cluster.", {"job": "chaos_manager", "node": node_ref['id']})
                            else:
                                loki.push_log(f"Watcher: Timeout aguardando nó {node_ref['id']}.", {"job": "chaos_manager", "node": node_ref['id']})
                        except Exception as exc:
                            loki.push_log(f"Watcher: Erro ao monitorar {node_ref['id']}: {exc}", {"job": "chaos_manager", "node": node_ref['id']})
            else:
                time.sleep(scenario.duration_sec)

        # 4) medir depois + limpar
        with tracer.start_as_current_span("measure_after_and_cleanup"):
            for idx, (node, ex) in enumerate(executors):
                try:
                    # lat_after = measure_latency(node["host"]) <-- Antigo
                    
                    lat_after_avg, loss_after_avg = measure_remote_latency(ex, target="8.8.8.8")
                    if lat_after_avg == 0.0 and loss_after_avg == 100.0:
                        lat_after_avg, loss_after_avg = measure_remote_latency(ex, target="192.168.1.196")
                    
                    # Medir latência HTTP ao agente (reflete o delay dentro do container)
                    http_lat_after = 0.0
                    http_error_after = None
                    if "metrics_url" in node:
                        res = probe_http(node["metrics_url"])
                        if res.response_time_ms:
                            http_lat_after = res.response_time_ms
                        if res.error:
                            http_error_after = res.error

                    metrics_raw = fetch_metrics_unified(node)

                    experiment["nodes"][idx].update({
                        "latency_after_ms": lat_after_avg,
                        "http_latency_after_ms": http_lat_after,
                        "http_error_after": http_error_after,
                        "loss_after_percent": loss_after_avg,
                        "metrics_after": metrics_raw,
                    })
                finally:
                    clear_netem(ex, node["net_if"])
                    loki.push_log(f"Caos removido do nó {node['id']}", {"job": "chaos_manager", "node": node['id']})

            # 4.1) HTTP Probes (After)
            if probes_cfg.get("scenarios", {}).get("default", {}).get("http", False):
                targets = probes_cfg.get("http_targets", [])
                for url in targets:
                    res = probe_http(url)
                    experiment["http_probes"]["after"].append({
                        "url": res.url,
                        "status": res.status_code,
                        "latency_ms": res.response_time_ms,
                        "error": res.error
                    })

        experiment["end_time"] = datetime.utcnow().isoformat() + "Z"

        out_path = LOGS_DIR / f"{experiment_id}.json"
        with out_path.open("w") as f:
            json.dump(experiment, f, indent=2)
        
        return out_path
