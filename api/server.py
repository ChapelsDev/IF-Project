# api/server.py
from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from typing import Optional, Dict, Any
from pathlib import Path
import glob
import json
import yaml
import time
import uuid

from chaos_manager.scenario_runner import run_scenario, ScenarioConfig
from reporting.html_report import generate_html_report
from reporting.charts import plot_latency_bar

app = FastAPI(title="Chaos/Eval API")

# Servir ficheiros estáticos (logs/relatórios)
Path("logs").mkdir(exist_ok=True)
app.mount("/logs", StaticFiles(directory="logs"), name="logs")

SSH_KEY_DEFAULT = str(Path.home() / ".ssh" / "chaos_local")
SCENARIOS_PATH = Path("config/scenarios.yaml")

# Armazenamento em memória dos jobs
JOBS: Dict[str, Any] = {}


# -------- MODELS -------- #

class RunRequest(BaseModel):
    scenario: str
    ssh_key: Optional[str] = None
    sudo_password: Optional[str] = None
    target_node: Optional[str] = None


class RunCustomRequest(BaseModel):
    scenario: str
    delay_ms: Optional[int] = None
    jitter_ms: Optional[int] = None
    loss_percent: Optional[float] = None
    duration_sec: Optional[int] = None
    ssh_key: Optional[str] = None
    sudo_password: Optional[str] = None
    target_node: Optional[str] = None


# -------- HELPERS -------- #

def _load_scenarios_yaml():
    if not SCENARIOS_PATH.exists():
        raise HTTPException(status_code=500, detail="config/scenarios.yaml not found")
    data = yaml.safe_load(SCENARIOS_PATH.read_text())

    # Suporta tanto:
    # scenarios:
    #   network_delay: ...
    # como:
    # network_delay: ...
    if "scenarios" in data:
        scenarios = data["scenarios"]
    else:
        scenarios = data

    return data, scenarios


def _save_scenarios_yaml(full_data):
    SCENARIOS_PATH.write_text(yaml.safe_dump(full_data, sort_keys=False))


def execute_job(job_id: str, scenario: str, ssh_key: str, sudo_password: Optional[str], override: Optional[ScenarioConfig] = None, target_node: Optional[str] = None):
    try:
        JOBS[job_id]["status"] = "running"
        # Executa o cenário (bloqueante, mas roda em background thread)
        result_path = run_scenario(scenario, ssh_key=ssh_key, sudo_password=sudo_password, scenario_override=override, target_node=target_node)
        
        # Lê o resultado
        with open(result_path) as f:
            data = json.load(f)
            
        # Gerar relatórios
        html_path = result_path.with_suffix(".html")
        img_path = result_path.with_suffix(".png")
        
        generate_html_report(data, html_path)
        plot_latency_bar(data, img_path)
            
        JOBS[job_id]["status"] = "done"
        JOBS[job_id]["result"] = data
        JOBS[job_id]["report_url"] = f"/logs/{html_path.name}"
        JOBS[job_id]["chart_url"] = f"/logs/{img_path.name}"
    except Exception as e:
        JOBS[job_id]["status"] = "error"
        JOBS[job_id]["error"] = str(e)


# -------- ENDPOINTS -------- #

@app.get("/scenarios")
def list_scenarios():
    """
    Lê o scenarios.yaml e devolve os cenários disponíveis com detalhes.
    """
    full, scenarios = _load_scenarios_yaml()
    return {"scenarios": scenarios}


@app.post("/experiments/run")
def run_experiment(req: RunRequest):
    """
    Executa um cenário de caos (sem override) e devolve o JSON resultante.
    """
    ssh_key = req.ssh_key or SSH_KEY_DEFAULT

    try:
        result = run_scenario(req.scenario, ssh_key=ssh_key, sudo_password=req.sudo_password, target_node=req.target_node)
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Chaos run failed: {e}")

    return result


@app.get("/experiments/job/{job_id}")
def get_job_status(job_id: str):
    if job_id not in JOBS:
        raise HTTPException(status_code=404, detail="Job not found")
    return JOBS[job_id]


@app.post("/experiments/run_custom")
def run_experiment_custom(req: RunCustomRequest, background_tasks: BackgroundTasks):
    """
    Override de delay/jitter/loss/duração para um cenário existente,
    atualizando o scenarios.yaml antes de correr o experimento.
    Executa em background para evitar timeouts de rede durante o caos.
    """
    ssh_key = req.ssh_key or SSH_KEY_DEFAULT

    full_data, scenarios = _load_scenarios_yaml()

    if req.scenario not in scenarios:
        raise HTTPException(status_code=404, detail=f"Scenario '{req.scenario}' not found")

    scen_data = scenarios[req.scenario]
    
    # Cria um objeto de configuração com os overrides (sem salvar no disco)
    # Copia os valores originais
    netem = scen_data.get("netem", {}).copy()
    duration = int(scen_data.get("duration_sec", 30))
    description = scen_data.get("description", "")

    # Aplica overrides
    if req.delay_ms is not None:
        netem["delay_ms"] = req.delay_ms
    if req.jitter_ms is not None:
        netem["jitter_ms"] = req.jitter_ms
    if req.loss_percent is not None:
        netem["loss_percent"] = req.loss_percent
    if req.duration_sec is not None:
        duration = req.duration_sec

    override_config = ScenarioConfig(
        name=req.scenario,
        description=description + " (Custom Run)",
        duration_sec=duration,
        netem=netem
    )

    # Inicia job em background
    job_id = str(uuid.uuid4())
    JOBS[job_id] = {
        "status": "pending",
        "scenario": req.scenario,
        "start_time": time.time()
    }
    
    background_tasks.add_task(execute_job, job_id, req.scenario, ssh_key, req.sudo_password, override_config, req.target_node)

    return {
        "job_id": job_id,
        "status": "started",
        "expected_duration_sec": duration
    }


@app.get("/experiments/latest")
def get_latest_experiment():
    """
    Devolve o conteúdo do último JSON em logs/*.json.
    """
    logs = sorted(glob.glob("logs/*.json"))
    if not logs:
        raise HTTPException(status_code=404, detail="No experiments yet")

    latest = logs[-1]
    with open(latest) as f:
        data = json.load(f)

    return data


# -------- FRONTEND SIMPLES -------- #
HTML_UI = """
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Chaos/Eval Web UI</title>
  <style>
    body { font-family: sans-serif; margin: 20px; background: #0b1120; color: #e5e7eb; }
    h1 { margin-bottom: 0.2rem; }
    small { color: #9ca3af; }
    label { display: block; margin-top: 0.8rem; }
    input, select {
      padding: 6px 8px;
      border-radius: 4px;
      border: 1px solid #374151;
      background: #020617;
      color: #e5e7eb;
      min-width: 160px;
    }
    button {
      margin-top: 1rem;
      padding: 8px 14px;
      border-radius: 4px;
      border: none;
      background: #2563eb;
      color: white;
      cursor: pointer;
    }
    button:hover { background: #1d4ed8; }
    .row { display: flex; gap: 1rem; flex-wrap: wrap; margin-top: 0.5rem; }
    .card {
      background: #020617;
      border-radius: 8px;
      padding: 1rem;
      border: 1px solid #111827;
      max-width: 900px;
    }
    pre {
      background: #020617;
      border-radius: 8px;
      padding: 0.75rem;
      border: 1px solid #111827;
      max-height: 400px;
      overflow: auto;
      font-size: 0.85rem;
    }
  </style>
</head>
<body>
  <h1>Chaos/Eval Web UI</h1>
  <small>Seleciona um cenário, ajusta os parâmetros e executa o experimento.</small>

  <div class="card" style="margin-top:1rem;">
    <h2 style="margin-top:0;">Configuração</h2>

    <label>
      Cenário:
      <select id="scenarioSelect">
        <option value="" disabled selected>-- a carregar cenários... --</option>
      </select>
    </label>

    <div class="row">
      <label>
        Delay (ms):
        <input type="number" id="delay" value="" placeholder="(usar valor do cenário)">
      </label>
      <label>
        Jitter (ms):
        <input type="number" id="jitter" value="" placeholder="(usar valor do cenário)">
      </label>
      <label>
        Loss (%):
        <input type="number" id="loss" step="0.1" value="" placeholder="(usar valor do cenário)">
      </label>
      <label>
        Duração (s):
        <input type="number" id="duration" value="" placeholder="(usar valor do cenário)">
      </label>
    </div>

    <label>
      SSH key (opcional):
      <input type="text" id="sshKey" style="min-width:320px;" placeholder="~/.ssh/chaos_local">
    </label>

    <label>
      Sudo Password (opcional):
      <input type="password" id="sudoPassword" style="min-width:320px;" placeholder="Senha do sudo (se necessário)">
    </label>

    <label>
      Target Node (opcional):
      <input type="text" id="targetNode" style="min-width:320px;" placeholder="ID ou Host (ex: worker-01, worker-02)">
    </label>

    <button id="runBtn">Run custom scenario</button>
  </div>

  <div class="card" style="margin-top:1rem;">
    <h2 style="margin-top:0;">Resultado</h2>
    <pre id="output">(nenhum experimento ainda)</pre>
  </div>

<script>
function fieldOrNull(id) {
  var el = document.getElementById(id);
  if (!el) return null;
  var v = el.value;
  if (v === "" || v === null) return null;
  return v;
}

var SCENARIOS_DATA = {};

function loadScenarios() {
  var sel = document.getElementById("scenarioSelect");
  var out = document.getElementById("output");

  // só por debug, para sabermos que a função correu
  console.log("loadScenarios() called");
  out.textContent = "(a carregar cenários...)";

  fetch("/scenarios")
    .then(function(resp) {
      return resp.json();
    })
    .then(function(data) {
      console.log("SCENARIOS RESPONSE:", data);
      sel.innerHTML = ""; // limpa o placeholder inicial

      SCENARIOS_DATA = data.scenarios || {};
      var arr = Object.keys(SCENARIOS_DATA);

      if (arr.length === 0) {
        var opt = document.createElement("option");
        opt.value = "";
        opt.textContent = "-- nenhum cenário encontrado --";
        opt.disabled = true;
        opt.selected = true;
        sel.appendChild(opt);
        out.textContent = "Nenhum cenário encontrado. Verifica config/scenarios.yaml.";
        return;
      }

      var placeholder = document.createElement("option");
      placeholder.value = "";
      placeholder.textContent = "-- selecione um cenário --";
      placeholder.disabled = true;
      placeholder.selected = true;
      sel.appendChild(placeholder);

      arr.forEach(function(name) {
        var opt = document.createElement("option");
        opt.value = name;
        opt.textContent = name;
        sel.appendChild(opt);
      });

      out.textContent = "Cenários disponíveis: " + JSON.stringify(arr);
    })
    .catch(function(e) {
      console.error("Erro a carregar /scenarios:", e);
      out.textContent = "Erro a carregar /scenarios: " + e;
      sel.innerHTML = "";
      var opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "-- erro a carregar cenários --";
      opt.disabled = true;
      opt.selected = true;
      sel.appendChild(opt);
    });
}

function onScenarioChange() {
  var sel = document.getElementById("scenarioSelect");
  var name = sel.value;
  var s = SCENARIOS_DATA[name];
  if (!s) return;

  var netem = s.netem || {};
  document.getElementById("delay").value = netem.delay_ms || 0;
  document.getElementById("jitter").value = netem.jitter_ms || 0;
  document.getElementById("loss").value = netem.loss_percent || 0;
  document.getElementById("duration").value = s.duration_sec || 30;
}

function runExperimentCustom() {
  var sel = document.getElementById("scenarioSelect");
  var out = document.getElementById("output");
  var scenario = sel.value;

  if (!scenario) {
    out.textContent = "Escolhe um cenário primeiro.";
    return;
  }

  var delay = fieldOrNull("delay");
  var jitter = fieldOrNull("jitter");
  var loss = fieldOrNull("loss");
  var duration = fieldOrNull("duration");
  var sshKey = fieldOrNull("sshKey");
  var sudoPassword = fieldOrNull("sudoPassword");
  var targetNode = fieldOrNull("targetNode");

  var payload = { scenario: scenario };
  if (delay !== null)   payload.delay_ms = parseInt(delay);
  if (jitter !== null)  payload.jitter_ms = parseInt(jitter);
  if (loss !== null)    payload.loss_percent = parseFloat(loss);
  if (duration !== null) payload.duration_sec = parseInt(duration);
  if (sshKey !== null)  payload.ssh_key = sshKey;
  if (sudoPassword !== null) payload.sudo_password = sudoPassword;
  if (targetNode !== null) payload.target_node = targetNode;

  var displayPayload = JSON.parse(JSON.stringify(payload));
  if (displayPayload.sudo_password) {
    displayPayload.sudo_password = "******";
  }

  out.textContent = "A iniciar experimento...\\n" + JSON.stringify(displayPayload, null, 2);

  fetch("/experiments/run_custom", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  })
    .then(function(resp) { return resp.json(); })
    .then(function(data) {
      if (data.job_id) {
        out.textContent += "\\n\\nJob iniciado: " + data.job_id + "\\nEsperando " + data.expected_duration_sec + "s...";
        
        // Espera a duração do teste + 2s de margem antes de tentar buscar o resultado
        // Isso evita tentar conectar enquanto a rede está em caos
        setTimeout(function() {
          pollJob(data.job_id);
        }, (data.expected_duration_sec + 2) * 1000);
      } else {
        out.textContent = JSON.stringify(data, null, 2);
      }
    })
    .catch(function(e) {
      out.textContent = "Erro a iniciar experimento: " + e;
    });
}

function pollJob(jobId) {
  var out = document.getElementById("output");
  out.textContent += "\\nVerificando resultado...";
  
  fetch("/experiments/job/" + jobId)
    .then(function(resp) { return resp.json(); })
    .then(function(data) {
      if (data.status === "done") {
        var html = "<h3>Sucesso!</h3>";
        html += "<p><a href='" + data.report_url + "' target='_blank' style='color:#60a5fa'>📄 Abrir Relatório HTML</a></p>";
        html += "<p><img src='" + data.chart_url + "' style='max-width:100%; border:1px solid #374151; border-radius:4px;'></p>";
        html += "<details><summary>Ver JSON Raw</summary><pre>" + JSON.stringify(data.result, null, 2) + "</pre></details>";
        
        // Substitui o conteúdo do <pre> por HTML rico
        var container = document.getElementById("output").parentNode;
        container.innerHTML = "<h2 style='margin-top:0;'>Resultado</h2>" + html;
        
      } else if (data.status === "error") {
        out.textContent = "Erro no job: " + data.error;
      } else {
        out.textContent += "\\nStatus: " + data.status + ". Tentando novamente em 2s...";
        setTimeout(function() { pollJob(jobId); }, 2000);
      }
    })
    .catch(function(e) {
      out.textContent += "\\nErro ao buscar resultado (rede instável?): " + e + "\\nTentando novamente em 5s...";
      setTimeout(function() { pollJob(jobId); }, 5000);
    });
}

// Garante que só corre depois do DOM estar carregado
document.addEventListener("DOMContentLoaded", function() {
  loadScenarios();
  var btn = document.getElementById("runBtn");
  btn.addEventListener("click", runExperimentCustom);
  var sel = document.getElementById("scenarioSelect");
  sel.addEventListener("change", onScenarioChange);
});
</script>
</body>
</html>
"""



@app.get("/ui", response_class=HTMLResponse)
def ui():
    """
    Frontend web simples para correr cenários customizados.
    """
    return HTML_UI
