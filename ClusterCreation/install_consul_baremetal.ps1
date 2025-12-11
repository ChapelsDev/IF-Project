# install_consul_windows.ps1

# --- Configuration ---
$ConsulExePath = "C:\Users\p060012\consul\consul.exe"  # UPDATE THIS to where your consul.exe is
$ConfigDir = "C:\Consul\config"
$DataDir = "C:\Consul\data"
$RetryJoinIP = "172.20.10.2" # The IP from your bash script

# 1. Create Directories
Write-Host "Creating directories..."
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# 2. Generate Basic Configuration (consul.hcl)
Write-Host "Generating configuration..."
$ConfigContent = @"
server = true
datacenter = "dc1"
data_dir = "$($DataDir.Replace('\', '\\'))"
bootstrap_expect = 2
ui = true
bind_addr = "172.20.10.8"
client_addr = "0.0.0.0"
retry_join = ["$RetryJoinIP"]
"@

Set-Content -Path "$ConfigDir\consul.hcl" -Value $ConfigContent

# 3. Create Windows Service (Equivalent to systemd)
Write-Host "Creating Windows Service..."

# Stop service if it already exists
if (Get-Service "Consul" -ErrorAction SilentlyContinue) {
    Stop-Service "Consul"
    sc.exe delete "Consul"
}

# Create the service
# Note: We use sc.exe because New-Service has limitations with arguments
$BinPath = "$ConsulExePath agent -config-dir=$ConfigDir"
sc.exe create "Consul" binPath= $BinPath start= auto displayname= "Consul Agent"

# 4. Start the Service
Write-Host "Starting Consul Service..."
Start-Service "Consul"

Write-Host "✅ Consul installed and running as a service!"
Write-Host "   UI available at http://localhost:8500/ui/"