# =====================================================================
# SalesFixr — enable the Windows features WSL 2 / Docker Desktop need.
#
# MUST be run as Administrator.  A reboot is required afterwards.
#
# Why this is needed: the WSL *app* can be installed from the Microsoft
# Store while the underlying Windows *optional components* are still off.
# When that happens, `wsl --status` reports
# WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED and Docker Desktop's engine
# silently fails to start (the CLI returns a 500 from the named pipe).
# =====================================================================

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal] `
      [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host "ERROR: this script must be run as Administrator." -ForegroundColor Red
  Write-Host "Right-click PowerShell -> Run as administrator, then run it again."
  Read-Host "Press Enter to close"
  exit 1
}

Write-Host ""
Write-Host "=== SalesFixr: enabling WSL 2 prerequisites ===" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------
# 1. Windows Subsystem for Linux
# ---------------------------------------------------------------------
Write-Host "[1/3] Enabling Microsoft-Windows-Subsystem-Linux ..." -ForegroundColor Yellow
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
Write-Host ""

# ---------------------------------------------------------------------
# 2. Virtual Machine Platform  (this is what makes it WSL *2*)
# ---------------------------------------------------------------------
Write-Host "[2/3] Enabling VirtualMachinePlatform ..." -ForegroundColor Yellow
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
Write-Host ""

# ---------------------------------------------------------------------
# 3. Default to WSL 2 for any distro
# ---------------------------------------------------------------------
Write-Host "[3/3] Setting WSL default version to 2 ..." -ForegroundColor Yellow
try { wsl.exe --set-default-version 2 } catch {
  Write-Host "  (expected to fail until after the reboot - ignore)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Green
Write-Host " DONE. You must now REBOOT for this to take effect."  -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "After rebooting:"
Write-Host "  1. Start Docker Desktop and wait for the whale icon to go steady."
Write-Host "  2. Run:  docker run --rm hello-world"
Write-Host ""

$answer = Read-Host "Reboot now? (y/N)"
if ($answer -eq 'y' -or $answer -eq 'Y') {
  Write-Host "Rebooting in 5 seconds... close this window to cancel."
  Start-Sleep -Seconds 5
  Restart-Computer -Force
} else {
  Write-Host "Reboot when you are ready. Nothing works until you do."
  Read-Host "Press Enter to close"
}
