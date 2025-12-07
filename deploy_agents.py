import yaml
import time
from pathlib import Path
from chaos_manager.ssh_executor import SSHExecutor, NodeSSHConfig

NODE_EXPORTER_URL = "https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz"
INSTALL_DIR = "/tmp/chaos_agent"

def load_nodes():
    with open("config/nodes.yaml") as f:
        return yaml.safe_load(f)["nodes"]

def deploy_to_node(node):
    print(f"🚀 A iniciar deploy em {node['id']} ({node['host']})...")
    
    # Configurar SSH
    ssh_key = str(Path.home() / ".ssh" / "chaos_local") # Ajusta se usares outra chave
    
    # Se a chave não existir, não a passamos para evitar erros
    if not Path(ssh_key).exists():
        ssh_key = None

    cfg = NodeSSHConfig(
        host=node["host"],
        user=node["ssh_user"],
        port=node.get("ssh_port", 22),
        sudo_password=node.get("sudo_password"),
        password=node.get("ssh_password") # Lê a senha do YAML se existir
    )
    executor = SSHExecutor(cfg, key_path=ssh_key)

    # 1. Verificar se já está a correr (com mais retries pois o nó pode estar a acordar)
    code, out, _ = executor.run("pgrep -f node_exporter", retries=10)
    if code == 0:
        print(f"✅ Node Exporter já está a correr em {node['id']}.")
    else:
        # 2. Criar diretoria e baixar (se não estiver a correr)
        print(f"📦 A baixar Node Exporter em {node['id']}...")
        cmds = [
            f"mkdir -p {INSTALL_DIR}",
            f"cd {INSTALL_DIR} && wget -q {NODE_EXPORTER_URL} -O node_exporter.tar.gz",
            f"cd {INSTALL_DIR} && tar xzf node_exporter.tar.gz",
            f"cd {INSTALL_DIR} && mv node_exporter-*/node_exporter .",
            f"chmod +x {INSTALL_DIR}/node_exporter"
        ]
        
        full_cmd = " && ".join(cmds)
        code, out, err = executor.run(full_cmd, retries=10)
        if code != 0:
            print(f"❌ Erro ao baixar/extrair: {err}")
            return

        # 3. Iniciar em background (nohup)
        print(f"▶️ A iniciar serviço...")
        # Usamos nohup para o processo não morrer quando o SSH fechar
        start_cmd = f"nohup {INSTALL_DIR}/node_exporter > {INSTALL_DIR}/node_exporter.log 2>&1 &"
        executor.run(start_cmd, retries=10)
        
        # 4. Verificar
        time.sleep(2)
        code, _, _ = executor.run("pgrep -f node_exporter", retries=10)
        if code == 0:
            print(f"✅ Sucesso! Node Exporter a correr em {node['id']}.")
        else:
            print(f"⚠️ Aviso: Não foi possível confirmar se o processo ficou a correr.")
            return

    # 5. Registar no Consul (Local) - SEMPRE
    # Como estamos num Consul Server, podemos registar via API local
    print(f"📝 A registar node-exporter no Consul em {node['id']}...")
    
    # Payload JSON
    register_payload = f'''
    {{
      "ID": "node-exporter-{node['host']}",
      "Name": "node-exporter",
      "Tags": ["metrics"],
      "Address": "{node['host']}",
      "Port": 9100,
      "Check": {{
        "HTTP": "http://{node['host']}:9100/metrics",
        "Interval": "10s"
      }}
    }}
    '''
    # Remove newlines para o comando shell
    register_payload = register_payload.replace("\\n", "").strip()
    
    reg_cmd = f"curl -X PUT --data '{register_payload}' http://127.0.0.1:8500/v1/agent/service/register"
    code_reg, out_reg, err_reg = executor.run(reg_cmd, retries=10)
    
    if code_reg == 0:
            print(f"✅ Serviço node-exporter registado no Consul.")
    else:
            print(f"⚠️ Falha ao registar no Consul: {err_reg}")

def main():
    nodes = load_nodes()
    for node in nodes:
        # Podes comentar isto se quiseres reinstalar no localhost também
        if node["host"] in ["127.0.0.1", "localhost"]:
            print(f"ℹ️ Saltando localhost ({node['id']})...")
            continue
            
        try:
            deploy_to_node(node)
        except Exception as e:
            print(f"❌ Falha ao conectar a {node['id']}: {e}")

if __name__ == "__main__":
    main()
