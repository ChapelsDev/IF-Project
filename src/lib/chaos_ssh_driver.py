import subprocess
import json
import re
from typing import Any, Dict

def run_ssh_command(host: str, user: str, command: str, password: str = None) -> str:
    """
    Executes a command via SSH and returns the stdout.
    Uses sshpass if password is provided.
    """
    if password:
        # sshpass -p 'password' ssh user@host command
        # Added -o UserKnownHostsFile=/dev/null to avoid writing to read-only /root/.ssh/known_hosts
        ssh_cmd = ["sshpass", "-p", password, "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", f"{user}@{host}", command]
    else:
        ssh_cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", f"{user}@{host}", command]
    
    try:
        result = subprocess.run(ssh_cmd, capture_output=True, text=True, check=True, timeout=10)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"SSH command failed: {e.stderr}")
    except Exception as e:
        raise RuntimeError(f"SSH connection failed: {str(e)}")

def _get_sudo_command(command: str, user: str, password: str) -> str:
    """Wraps command with sudo if user is not root."""
    if user == 'root':
        return command
    if password:
        # -S reads password from stdin
        return f"echo '{password}' | sudo -S {command}"
    return f"sudo {command}"

def inject_network_delay(target_host: str, ssh_user: str, latency: str = "200ms", device: str = "eth0", ssh_password: str = None) -> str:
    """
    Injects network delay using 'tc' (Traffic Control) via SSH.
    Returns the device name as the 'UID' for rollback.
    """
    # Using tc instead of chaosd
    # tc qdisc add dev eth0 root netem delay 200ms
    
    # Clean up any existing qdisc first to be safe (ignore error)
    del_cmd = f"tc qdisc del dev {device} root"
    del_cmd = _get_sudo_command(del_cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, del_cmd, ssh_password)
    except:
        pass

    # Use 'replace' instead of 'add' to be more robust if qdisc already exists
    cmd = f"tc qdisc replace dev {device} root netem delay {latency}"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return device # Return device as UID for rollback
    except RuntimeError as e:
        raise RuntimeError(f"Failed to inject network delay with tc: {e}")

def recover_network_delay(target_host: str, ssh_user: str, uid: str, ssh_password: str = None) -> None:
    """
    Recovers the network delay attack using 'tc'.
    The 'uid' parameter is expected to be the device name (e.g., 'eth0').
    """
    device = uid
    cmd = f"tc qdisc del dev {device} root"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    # We ignore errors on rollback in case it was already cleared
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
    except RuntimeError as e:
        # Log the error but don't fail the experiment status if it's just "file exists" or similar
        print(f"Warning: Failed to rollback network delay: {e}")
