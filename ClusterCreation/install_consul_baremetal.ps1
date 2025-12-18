# install_consul_windows.ps1

# Check for Administrator privileges
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "You do not have Administrator rights to run this script!`nPlease re-run this script as an Administrator!"
    break
}

# --- Configuration ---
$ConsulExePath = "C:\Users\p060012\consul\consul.exe"  # UPDATE THIS to where your consul.exe is
$ConfigDir = "C:\Users\p060012\consul\config"
$DataDir = "C:\Users\p060012\consul\data"
$RetryJoinIP = "192.168.100.53" # The IP from your bash script

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
bootstrap_expect = 3
ui = true
bind_addr = "192.168.100.149"
client_addr = "0.0.0.0"
retry_join = ["$RetryJoinIP"]
"@

Set-Content -Path "$ConfigDir\consul.hcl" -Value $ConfigContent

# 3. Create Windows Service (Equivalent to systemd)
Write-Host "Creating Windows Service..."

# Stop service if it already exists
if (Get-Service "Consul" -ErrorAction SilentlyContinue) {
    Write-Host "Stopping existing Consul service..."
    Stop-Service "Consul"
    Start-Sleep -Seconds 2
    sc.exe delete "Consul"
    Start-Sleep -Seconds 2
}

# Create the service
# Note: We use sc.exe because New-Service has limitations with arguments
$BinPath = "$ConsulExePath agent -config-dir=$ConfigDir"
sc.exe create "Consul" binPath= $BinPath start= auto displayname= "Consul Agent"

# 4. Start the Service
Write-Host "Starting Consul Service..."
try {
    Start-Service "Consul" -ErrorAction Stop
    Write-Host "✅ Consul installed and running as a service!"
}
catch {
    Write-Error "Failed to start Consul service. Please check if you are running as Administrator or if the path to consul.exe is correct."
    Write-Error $_
    exit 1
}
Write-Host "   UI available at http://localhost:8500/ui/"