# setup.ps1 - Post-install configuration for Windows Server 2022
# Runs via FirstLogonCommands from autounattend.xml

# DNS
Set-DnsClientServerAddress -InterfaceAlias 'Ethernet*' -ServerAddresses 8.8.8.8,8.8.4.4

# SSH Server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22

# RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'

# Chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Git
choco install git -y

# WSL2 features
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart

# WSL2 kernel (inbox version)
$wslMsi = "$env:TEMP\wsl_update.msi"
Invoke-WebRequest -Uri https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi -OutFile $wslMsi
msiexec /i $wslMsi /quiet /norestart
Start-Sleep 10

# Schedule part 2: Windows Update + new WSL + Ubuntu (runs after reboot)
@'
# Part 2 - runs after reboot for WSL features
Add-Content C:\setup-log.txt "Part2 started at $(Get-Date)"

# Install Windows Updates via COM as SYSTEM
$session = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()
$results = $searcher.Search("IsInstalled=0")
Add-Content C:\setup-log.txt "Found $($results.Updates.Count) updates"
if ($results.Updates.Count -gt 0) {
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $results.Updates
    $downloader.Download() | Out-Null
    Add-Content C:\setup-log.txt "Downloaded at $(Get-Date)"
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $results.Updates
    $r = $installer.Install()
    Add-Content C:\setup-log.txt "Installed: result=$($r.ResultCode) reboot=$($r.RebootRequired) at $(Get-Date)"
}

# Install new WSL from GitHub
$wslMsi = "$env:TEMP\wsl.msi"
Invoke-WebRequest -Uri https://github.com/microsoft/WSL/releases/download/2.6.3/wsl.2.6.3.0.x64.msi -OutFile $wslMsi -UseBasicParsing
msiexec /i $wslMsi /quiet /norestart
Start-Sleep 15
Add-Content C:\setup-log.txt "WSL MSI installed at $(Get-Date)"

# Set WSL2 default and install Ubuntu
& "C:\Program Files\WSL\wsl.exe" --set-default-version 2
& "C:\Program Files\WSL\wsl.exe" --install Ubuntu --no-launch
Add-Content C:\setup-log.txt "Ubuntu installed at $(Get-Date)"

# Cleanup
Unregister-ScheduledTask -TaskName SetupPart2 -Confirm:$false

# Reboot if updates needed it
if ($results.Updates.Count -gt 0 -and $r.RebootRequired) {
    Add-Content C:\setup-log.txt "Rebooting for updates"
    shutdown /r /t 60
}
'@ | Out-File -FilePath 'C:\setup-part2.ps1' -Encoding UTF8

# Register part2 as SYSTEM task (survives DISM reboot)
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -File C:\setup-part2.ps1'
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName 'SetupPart2' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force

Add-Content C:\setup-log.txt "Part1 done, part2 scheduled at $(Get-Date)"

# DISM activation LAST - this forces a reboot
dism /online /set-edition:ServerStandard /productkey:RNKHH-MMFB3-RFYX2-HRH4H-QPHHB /accepteula /quiet
# If DISM didn't reboot, do it manually
Restart-Computer -Force
