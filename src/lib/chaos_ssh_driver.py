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

def _get_current_netem_params(target_host: str, ssh_user: str, device: str, ssh_password: str = None) -> str:
    """
    Checks if there is an existing netem qdisc and returns its parameters (e.g., 'delay 200ms loss 10%').
    Returns empty string if no netem qdisc exists.
    """
    cmd = f"tc qdisc show dev {device}"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        output = run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        # Output example: qdisc netem 8001: root refcnt 2 limit 1000 delay 200.0ms loss 10%
        if "netem" in output:
            # Extract relevant parameters (delay, loss, duplicate, corrupt, reorder)
            params = []
            
            # Regex to find delay (e.g., delay 200.0ms)
            delay_match = re.search(r'delay\s+([0-9\.]+ms)', output)
            if delay_match:
                params.append(f"delay {delay_match.group(1)}")
                
            # Regex to find loss (e.g., loss 10%)
            loss_match = re.search(r'loss\s+([0-9\.]+\%?)', output)
            if loss_match:
                params.append(f"loss {loss_match.group(1)}")
                
            return " ".join(params)
    except:
        pass
    return ""

def inject_network_delay(target_host: str, ssh_user: str, latency: str = "200ms", device: str = "eth0", ssh_password: str = None) -> str:
    """
    Injects network delay using 'tc' (Traffic Control) via SSH.
    Preserves existing packet loss if present.
    """
    # Check for existing params to preserve loss if we are just adding delay
    current_params = _get_current_netem_params(target_host, ssh_user, device, ssh_password)
    
    new_params = []
    if "loss" in current_params:
        # Keep existing loss
        loss_match = re.search(r'loss\s+([0-9\.]+\%?)', current_params)
        if loss_match:
            new_params.append(f"loss {loss_match.group(1)}")
    
    # Add new delay
    new_params.append(f"delay {latency}")
    
    params_str = " ".join(new_params)
    
    # Use 'replace' to update the qdisc
    cmd = f"tc qdisc replace dev {device} root netem {params_str}"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return device
    except RuntimeError as e:
        raise RuntimeError(f"Failed to inject network delay: {e}")

def recover_network_delay(target_host: str, ssh_user: str, uid: str, ssh_password: str = None) -> None:
    """
    Recovers the network delay attack.
    If packet loss was also active, we should ideally keep it, but for "Stop All" we usually want to clear everything.
    For individual stop, this might clear both. This is a known limitation of simple 'tc' wrappers.
    For now, we clear everything to be safe.
    """
    device = uid
    cmd = f"tc qdisc del dev {device} root"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
    except RuntimeError as e:
        print(f"Warning: Failed to rollback network delay: {e}")

import time

def wait_seconds(seconds: Any) -> None:
    """
    Waits for the specified number of seconds.
    Handles string input by casting to int.
    """
    try:
        s = int(str(seconds).replace('s', ''))
        time.sleep(s)
    except ValueError:
        print(f"Warning: Invalid duration '{seconds}', defaulting to 30s")
        time.sleep(30)

def inject_packet_loss(target_host: str, ssh_user: str, loss: str = "10%", device: str = "eth0", ssh_password: str = None) -> str:
    """
    Injects packet loss using 'tc' (Traffic Control) via SSH.
    Preserves existing network delay if present.
    """
    # Check for existing params to preserve delay if we are just adding loss
    current_params = _get_current_netem_params(target_host, ssh_user, device, ssh_password)
    
    new_params = []
    if "delay" in current_params:
        # Keep existing delay
        delay_match = re.search(r'delay\s+([0-9\.]+ms)', current_params)
        if delay_match:
            new_params.append(f"delay {delay_match.group(1)}")
            
    # Add new loss
    new_params.append(f"loss {loss}")
    
    params_str = " ".join(new_params)

    # tc qdisc replace dev eth0 root netem ...
    cmd = f"tc qdisc replace dev {device} root netem {params_str}"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return device
    except RuntimeError as e:
        raise RuntimeError(f"Failed to inject packet loss: {e}")

def recover_packet_loss(target_host: str, ssh_user: str, uid: str, ssh_password: str = None) -> None:
    """
    Recovers the packet loss attack.
    """
    recover_network_delay(target_host, ssh_user, uid, ssh_password)
