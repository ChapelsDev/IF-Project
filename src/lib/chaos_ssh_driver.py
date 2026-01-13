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

            # Regex to find duplicate (e.g., duplicate 1%)
            dup_match = re.search(r'duplicate\s+([0-9\.]+\%?)', output)
            if dup_match:
                params.append(f"duplicate {dup_match.group(1)}")

            # Regex to find reorder (e.g., reorder 5%)
            reorder_match = re.search(r'reorder\s+([0-9\.]+\%?)', output)
            if reorder_match:
                params.append(f"reorder {reorder_match.group(1)}")
                
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

def inject_packet_corruption(target_host: str, ssh_user: str, corruption: str = "10%", device: str = "eth0", ssh_password: str = None) -> str:
    """
    Injects packet corruption using 'tc' (Traffic Control) via SSH.
    """
    # Check for existing params
    current_params = _get_current_netem_params(target_host, ssh_user, device, ssh_password)
    
    new_params = []
    # Preserve existing delay/loss if possible (simplified logic here)
    if "delay" in current_params:
        delay_match = re.search(r'delay\s+([0-9\.]+ms)', current_params)
        if delay_match:
            new_params.append(f"delay {delay_match.group(1)}")
    if "loss" in current_params:
        loss_match = re.search(r'loss\s+([0-9\.]+\%?)', current_params)
        if loss_match:
            new_params.append(f"loss {loss_match.group(1)}")

    new_params.append(f"corrupt {corruption}")
    
    params_str = " ".join(new_params)
    cmd = f"tc qdisc replace dev {device} root netem {params_str}"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return device
    except RuntimeError as e:
        raise RuntimeError(f"Failed to inject packet corruption: {e}")

def recover_packet_corruption(target_host: str, ssh_user: str, uid: str, ssh_password: str = None) -> None:
    recover_network_delay(target_host, ssh_user, uid, ssh_password)

def inject_bandwidth_limit(target_host: str, ssh_user: str, rate: str = "1mbit", burst: str = "32kbit", latency: str = "400ms", device: str = "eth0", ssh_password: str = None) -> str:
    """
    Injects bandwidth limit using 'tc' TBF (Token Bucket Filter).
    """
    cmd = f"tc qdisc replace dev {device} root tbf rate {rate} burst {burst} latency {latency}"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return device
    except RuntimeError as e:
        raise RuntimeError(f"Failed to inject bandwidth limit: {e}")

def recover_bandwidth_limit(target_host: str, ssh_user: str, uid: str, ssh_password: str = None) -> None:
    recover_network_delay(target_host, ssh_user, uid, ssh_password)

def inject_packet_duplication(target_host: str, ssh_user: str, duplication: str = "1%", device: str = "eth0", ssh_password: str = None) -> str:
    """
    Injects packet duplication using 'tc' (Traffic Control) via SSH.
    """
    current_params = _get_current_netem_params(target_host, ssh_user, device, ssh_password)
    new_params = []
    
    # Preserve existing params
    if "delay" in current_params:
        delay_match = re.search(r'delay\s+([0-9\.]+ms)', current_params)
        if delay_match: new_params.append(f"delay {delay_match.group(1)}")
    if "loss" in current_params:
        loss_match = re.search(r'loss\s+([0-9\.]+\%?)', current_params)
        if loss_match: new_params.append(f"loss {loss_match.group(1)}")

    if "reorder" in current_params:
        reorder_match = re.search(r'reorder\s+([0-9\.]+\%?)', current_params)
        if reorder_match: new_params.append(f"reorder {reorder_match.group(1)} 50%")
        
    new_params.append(f"duplicate {duplication}")
    
    params_str = " ".join(new_params)
    cmd = f"tc qdisc replace dev {device} root netem {params_str}"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return device
    except RuntimeError as e:
        raise RuntimeError(f"Failed to inject packet duplication: {e}")

def recover_packet_duplication(target_host: str, ssh_user: str, uid: str, ssh_password: str = None) -> None:
    recover_network_delay(target_host, ssh_user, uid, ssh_password)

def inject_packet_reordering(target_host: str, ssh_user: str, reordering: str = "5%", device: str = "eth0", ssh_password: str = None) -> str:
    """
    Injects packet reordering using 'tc' (Traffic Control) via SSH.
    Note: Reordering usually requires a delay to be effective in netem.
    If no delay exists, we add a small one (10ms) to make reordering work.
    """
    current_params = _get_current_netem_params(target_host, ssh_user, device, ssh_password)
    new_params = []
    
    has_delay = False
    if "delay" in current_params:
        delay_match = re.search(r'delay\s+([0-9\.]+ms)', current_params)
        if delay_match: 
            new_params.append(f"delay {delay_match.group(1)}")
            has_delay = True
    
    if not has_delay:
        # Delay must be larger than ping interval (50ms) for reordering to be detected
        new_params.append("delay 75ms")

    if "loss" in current_params:
        loss_match = re.search(r'loss\s+([0-9\.]+\%?)', current_params)
        if loss_match: new_params.append(f"loss {loss_match.group(1)}")

    if "duplicate" in current_params:
        dup_match = re.search(r'duplicate\s+([0-9\.]+\%?)', current_params)
        if dup_match: new_params.append(f"duplicate {dup_match.group(1)}")

    # reorder 25% 50% (25% of packets are sent immediately, others are delayed)
    # Simplified here to just take one value
    new_params.append(f"reorder {reordering} 50%")
    
    params_str = " ".join(new_params)
    cmd = f"tc qdisc replace dev {device} root netem {params_str}"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return device
    except RuntimeError as e:
        raise RuntimeError(f"Failed to inject packet reordering: {e}")

def recover_packet_reordering(target_host: str, ssh_user: str, uid: str, ssh_password: str = None) -> None:
    recover_network_delay(target_host, ssh_user, uid, ssh_password)

def inject_network_partition(target_host: str, ssh_user: str, partition_target: str, device: str = "eth0", ssh_password: str = None) -> str:
    """
    Injects network partition using 'ip route blackhole'.
    This is often more robust than iptables as it bypasses firewall chains.
    """
    if not partition_target:
        raise ValueError("Partition target IP is required")

    # Add a blackhole route for the specific IP
    cmd = f"ip route add blackhole {partition_target}"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return partition_target
    except RuntimeError as e:
        # If route already exists, try to replace it just in case
        if "File exists" in str(e):
            try:
                cmd_replace = f"ip route replace blackhole {partition_target}"
                cmd_replace = _get_sudo_command(cmd_replace, ssh_user, ssh_password)
                run_ssh_command(target_host, ssh_user, cmd_replace, ssh_password)
                return partition_target
            except:
                pass
        raise RuntimeError(f"Failed to inject network partition: {e}")

def recover_network_partition(target_host: str, ssh_user: str, uid: str, ssh_password: str = None) -> None:
    """
    Recovers network partition by removing the blackhole route.
    """
    partition_target = uid
    
    cmd = f"ip route del blackhole {partition_target}"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
    except Exception as e:
        print(f"ERROR: Failed to rollback network partition: {e}")
        import sys
        print(f"ERROR: Failed to rollback network partition: {e}", file=sys.stderr)

import base64

def inject_cpu_stress(target_host: str, ssh_user: str, duration: str = "60", load: str = "100", ssh_password: str = None) -> str:
    """
    Injects CPU stress by running a Python script that consumes a % of all cores.
    Returns the PID of the parent process.
    """
    # Clean duration string (remove 's')
    try:
        dur = int(str(duration).replace('s', ''))
    except:
        dur = 60
    
    # Parse load
    try:
        load_pct = int(str(load).replace('%', ''))
        if load_pct < 0: load_pct = 100
        if load_pct > 100: load_pct = 100
    except:
        load_pct = 100

    # Python script to burn cores with load control
    py_script = f"""
import multiprocessing, time, os, signal, sys

def burn(load):
    # Cycle 100ms
    chunk = 0.1 
    if load >= 100:
        while True: pass
    
    on_time = chunk * (load / 100.0)
    # Correct sleep time (subtract overhead not needed for simple logic)
    off_time = chunk - on_time
    
    while True:
        start = time.time()
        # Busy loop
        while time.time() - start < on_time:
            pass 
        time.sleep(off_time)

if __name__ == '__main__':
    # Launch process for every core
    procs = [multiprocessing.Process(target=burn, args=({load_pct},)) for _ in range(multiprocessing.cpu_count())]
    [p.start() for p in procs]
    
    def handler(signum, frame):
        [p.terminate() for p in procs]
        sys.exit(0)
    
    signal.signal(signal.SIGTERM, handler)
    time.sleep({dur})
    [p.terminate() for p in procs]
"""
    
    # Encode script to base64 to avoid shell escaping issues
    encoded_script = base64.b64encode(py_script.encode('utf-8')).decode('utf-8')
    
    # Command to decode and run
    # We add a dummy argument 'chaos_cpu_stress' to make it easy to kill
    cmd = f"nohup sh -c \"echo {encoded_script} | base64 -d | python3 - chaos_cpu_stress\" > /dev/null 2>&1 & echo $!"
    
    try:
        pid = run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return pid
    except RuntimeError as e:
        raise RuntimeError(f"Failed to inject CPU stress: {e}")

def recover_cpu_stress(target_host: str, ssh_user: str, uid: str, ssh_password: str = None) -> None:
    """
    Recovers CPU stress by killing the process and its children.
    """
    pid = uid
    # Kill children (python process) first, then the shell
    # Also kill by name just in case
    cmd = f"pkill -f chaos_cpu_stress; pkill -P {pid}; kill {pid}"
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
    except: pass

def inject_memory_stress(target_host: str, ssh_user: str, size_mb: str = "512", duration: str = "60", ssh_password: str = None) -> str:
    """
    Injects Memory stress by allocating a large string in Python.
    """
    try:
        dur = int(str(duration).replace('s', ''))
    except:
        dur = 60
        
    try:
        size = int(str(size_mb).replace('MB', '').replace('mb', ''))
    except:
        size = 512
    
    py_script = f"""
import time
try:
    x = 'a' * ({size} * 1024 * 1024)
    time.sleep({dur})
except MemoryError:
    print("Memory Error")
"""
    
    # Encode script to base64 to avoid shell escaping issues
    encoded_script = base64.b64encode(py_script.encode('utf-8')).decode('utf-8')
    
    # Command to decode and run
    # We add a dummy argument 'chaos_memory_stress' to make it easy to kill
    cmd = f"nohup sh -c \"echo {encoded_script} | base64 -d | python3 - chaos_memory_stress\" > /dev/null 2>&1 & echo $!"
    
    try:
        pid = run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return pid
    except RuntimeError as e:
        raise RuntimeError(f"Failed to inject Memory stress: {e}")

def recover_memory_stress(target_host: str, ssh_user: str, uid: str, ssh_password: str = None) -> None:
    pid = uid
    # Kill children (python process) first, then the shell
    # Also kill by name just in case
    cmd = f"pkill -f chaos_memory_stress; pkill -P {pid}; kill {pid}"
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
    except: pass

def inject_process_killer(target_host: str, ssh_user: str, process_name: str, ssh_password: str = None) -> str:
    """
    Kills a process by name using pkill -9.
    """
    if not process_name:
        raise ValueError("Process name is required")
        
    # 1. Try to find PIDs first (debug info)
    # We use bash -c to handle pipes/redirection if needed
    find_cmd = f"pgrep -f '{process_name}'"
    find_cmd = f"bash -c \"{find_cmd}\""
    find_cmd = _get_sudo_command(find_cmd, ssh_user, ssh_password)
    
    try:
        pids = run_ssh_command(target_host, ssh_user, find_cmd, ssh_password)
        if not pids:
            print(f"Warning: No process found matching '{process_name}' before kill.")
    except:
        pass

    # 2. Kill aggressively
    # pkill -9 -f <name> (matches full command line)
    # Wrapped in bash -c to ensure sudo handles quotes correctly
    cmd = f"pkill -9 -f '{process_name}'"
    cmd = f"bash -c \"{cmd}\""
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return process_name
    except RuntimeError as e:
        # Ignore if process not found (exit code 1)
        if "1" in str(e):
            return process_name
        raise RuntimeError(f"Failed to kill process: {e}")

def recover_process_killer(target_host: str, ssh_user: str, uid: str, ssh_password: str = None) -> None:
    """
    No automatic recovery for process killer (service should restart itself).
    """
    pass

def inject_disk_fill(target_host: str, ssh_user: str, percent: str = "95", ssh_password: str = None) -> str:
    """
    Fills disk space on the root partition using a Python script.
    Calculates the amount needed to reach the target percentage of TOTAL disk space.
    """
    try:
        pct = int(str(percent).replace('%', ''))
        if pct > 100: pct = 100
        if pct < 1: pct = 1
    except:
        pct = 95
        
    # Python script to calculate and fill disk
    py_script = f"""
import os
import shutil
import sys

def fill_disk(percent):
    path = "/"
    filename = "/chaos_disk_fill"
    
    try:
        total, used, free = shutil.disk_usage(path)
        
        # If file exists, subtract its size from 'used' to get 'base usage'
        base_used = used
        if os.path.exists(filename):
            base_used -= os.path.getsize(filename)
            
        # Calculate target used bytes
        target_used = int(total * (percent / 100.0))
        
        # Calculate how many bytes we need to add to base_used to reach target_used
        needed_fill = target_used - base_used
        
        if needed_fill <= 0:
            print(f"Disk usage already above {{percent}}%.")
            return

        # Don't try to fill more than available free space (avoid crash)
        if needed_fill > free:
            needed_fill = free - (1024 * 1024) # Leave 1MB breathing room
            
        if needed_fill <= 0:
             return

        print(f"Filling {{needed_fill}} bytes to reach {{percent}}%")
        
        with open(filename, "wb") as f:
            # Try fallocate first (fast)
            try:
                # os.posix_fallocate(fd, offset, len)
                os.posix_fallocate(f.fileno(), 0, needed_fill)
            except (AttributeError, OSError):
                # Fallback: write zeros in chunks
                chunk_size = 10 * 1024 * 1024 # 10MB
                written = 0
                while written < needed_fill:
                    to_write = min(chunk_size, needed_fill - written)
                    f.write(b'\\0' * to_write)
                    written += to_write
                     
    except Exception as e:
        sys.stderr.write(f"Error: {{e}}\\n")
        sys.exit(1)

if __name__ == "__main__":
    fill_disk({pct})
"""
    
    # Encode script to base64 to avoid shell escaping issues
    encoded_script = base64.b64encode(py_script.encode('utf-8')).decode('utf-8')
    
    # Command to decode and run
    # FIX: Wrap in bash -c so the pipe runs under sudo
    # Added 'chaos_disk_fill' as argument to python3 for easier pkill
    # Use nohup ... & to run in background so we don't block/timeout
    inner_cmd = f"nohup sh -c \"echo {encoded_script} | base64 -d | python3 - chaos_disk_fill\" > /dev/null 2>&1 & echo $!"
    cmd = f"bash -c '{inner_cmd}'"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
        return "/chaos_disk_fill"
    except RuntimeError as e:
        raise RuntimeError(f"Failed to inject Disk Fill: {e}")

def recover_disk_fill(target_host: str, ssh_user: str, uid: str = None, ssh_password: str = None) -> None:
    """
    Removes the temporary file.
    """
    # 1. Kill the process first to release file handle
    kill_cmd = "pkill -f chaos_disk_fill"
    kill_cmd = _get_sudo_command(kill_cmd, ssh_user, ssh_password)
    try:
         run_ssh_command(target_host, ssh_user, kill_cmd, ssh_password)
    except: pass

    # 2. Remove the file
    file_path = uid if uid else "/chaos_disk_fill"
    cmd = f"rm -f {file_path}"
    cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
    try:
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
    except: pass

def cleanup_node(target_host: str, ssh_user: str, device: str = "eth0", ssh_password: str = None) -> None:
    """
    Aggressively cleans up all known chaos artifacts from the node.
    Used for 'Force Stop'.
    """
    # 1. Kill Stress Processes (CPU/Memory/Disk) FIRST
    # Kill processes matching the specific markers we added
    try:
        # Wrap in bash -c to ensure all commands run under sudo
        cmd = "bash -c 'pkill -f chaos_cpu_stress; pkill -f chaos_memory_stress; pkill -f chaos_disk_fill'"
        cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
    except: pass

    # 2. Clean Disk Fill (Remove file)
    # Only after killing the process to ensure handle is released
    recover_disk_fill(target_host, ssh_user, "/chaos_disk_fill", ssh_password)

    # 3. Clean Network (TC)
    try:
        # Delete root qdisc (removes delay, loss, dup, reorder, bandwidth)
        cmd = f"tc qdisc del dev {device} root"
        cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
    except: pass

    # 4. Clean Network Partitions (Blackhole routes)
    try:
        # List blackhole routes and delete them
        # ip route show type blackhole -> "blackhole 1.2.3.4"
        cmd = "ip route show type blackhole | awk '{print $2}' | xargs -I {} ip route del blackhole {}"
        cmd = _get_sudo_command(cmd, ssh_user, ssh_password)
        run_ssh_command(target_host, ssh_user, cmd, ssh_password)
    except: pass

