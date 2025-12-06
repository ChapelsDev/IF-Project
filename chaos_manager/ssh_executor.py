from __future__ import annotations
import time
import paramiko
from dataclasses import dataclass


@dataclass
class NodeSSHConfig:
    host: str
    user: str
    port: int = 22
    sudo_password: str | None = None
    password: str | None = None  # Senha SSH opcional


class SSHExecutor:
    """
    Wrapper simples em volta de paramiko para correr comandos via SSH.
    """

    def __init__(self, ssh_config: NodeSSHConfig, key_path: str | None = None):
        self.cfg = ssh_config
        self.key_path = key_path

    def _connect(self) -> paramiko.SSHClient:
        base_args = {
            "hostname": self.cfg.host,
            "port": self.cfg.port,
            "username": self.cfg.user,
            "timeout": 10,
            "banner_timeout": 30,
        }

        # 1. Tentar com chave SSH primeiro
        if self.key_path:
            client = paramiko.SSHClient()
            client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            try:
                pkey = paramiko.RSAKey.from_private_key_file(self.key_path)
                # Tenta conectar SÓ com a chave primeiro
                client.connect(**base_args, pkey=pkey)
                return client
            except Exception:
                client.close()
                # Se falhar, ignora e tenta o próximo método (senha)
                pass

        # 2. Tentar com senha se definida
        if self.cfg.password:
            client = paramiko.SSHClient()
            client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            try:
                client.connect(**base_args, password=self.cfg.password, look_for_keys=False, allow_agent=False)
                return client
            except Exception as e:
                client.close()
                # Se falhar com senha, lança o erro real
                raise e
        
        # Se chegou aqui, tentou chave (e falhou) e não tinha senha, ou não tinha nada.
        # Tenta conectar sem nada (agente ssh ou sem senha) como última esperança
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(**base_args)
            return client
        except Exception as e:
            client.close()
            raise Exception(f"Falha de autenticação SSH para {self.cfg.user}@{self.cfg.host}. Verifique chave ou senha.")

    def run(self, cmd: str, retries: int = 3) -> tuple[int, str, str]:
        # Se tivermos password de sudo e o comando for sudo, injetamos a password
        if self.cfg.sudo_password and cmd.strip().startswith("sudo"):
            # Remove o "sudo" inicial e substitui por "echo PASS | sudo -S"
            # Ex: "sudo tc ..." -> "echo 'pass' | sudo -S tc ..."
            cmd_body = cmd.strip()[4:].strip()
            cmd = f"echo '{self.cfg.sudo_password}' | sudo -S {cmd_body}"

        last_exception = None
        for attempt in range(retries):
            client = None
            try:
                client = self._connect()
                stdin, stdout, stderr = client.exec_command(cmd)
                exit_code = stdout.channel.recv_exit_status()
                out = stdout.read().decode(errors="ignore")
                err = stderr.read().decode(errors="ignore")
                return exit_code, out, err
            except Exception as e:
                last_exception = e
                time.sleep(1)  # Espera um pouco antes de tentar novamente
            finally:
                if client:
                    client.close()
        
        return -1, "", f"SSH Error after {retries} retries: {str(last_exception)}"
