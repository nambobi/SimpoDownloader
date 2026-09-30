# SimpoDownloader installer for Windows (current user only, no admin needed).
# Install or reinstall by pasting this ONE line into PowerShell:
#   irm https://raw.githubusercontent.com/nambobi/SimpoDownloader/main/install.ps1 | iex
# Afterwards type:  simpodl

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

$RepoRaw    = 'https://raw.githubusercontent.com/nambobi/SimpoDownloader/main'
$InstallDir = Join-Path $env:LOCALAPPDATA 'SimpoDownloader'
$LibDir     = Join-Path $InstallDir 'lib'

Write-Host ''
Write-Host 'Installing SimpoDownloader...' -ForegroundColor Cyan
New-Item -ItemType Directory -Path $LibDir -Force | Out-Null

# 1. get the program (from this folder if run locally, otherwise from GitHub)
$target = Join-Path $LibDir 'simpodl.ps1'
$localCopy = $null
if ($PSScriptRoot) { $localCopy = Join-Path $PSScriptRoot 'simpodl.ps1' }
if ($localCopy -and (Test-Path -LiteralPath $localCopy)) {
    Copy-Item -LiteralPath $localCopy -Destination $target -Force
} else {
    Invoke-WebRequest -Uri "$RepoRaw/simpodl.ps1" -UseBasicParsing -OutFile $target
}
try { Unblock-File -LiteralPath $target } catch {}

# 2. the  simpodl  command: a tiny .cmd, so it works in cmd AND PowerShell without execution-policy errors
$cmd = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0lib\simpodl.ps1`" %*`r`nexit /b %errorlevel%`r`n"
[IO.File]::WriteAllText((Join-Path $InstallDir 'simpodl.cmd'), $cmd, [Text.Encoding]::ASCII)

# 3. add the folder to the user's PATH (kept as REG_EXPAND_SZ so %VARIABLES% in PATH keep working)
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
$userPath = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
if (-not ($parts | Where-Object { $_.TrimEnd('\') -eq $InstallDir.TrimEnd('\') })) {
    $key.SetValue('Path', ((@($parts) + $InstallDir) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    # tell Windows the environment changed so newly opened terminals see it
    [Environment]::SetEnvironmentVariable('SIMPODL_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('SIMPODL_REFRESH', $null, 'User')
}
$key.Close()
# ...and make it work in THIS window straight away
if (($env:Path -split ';') -notcontains $InstallDir) { $env:Path = "$env:Path;$InstallDir" }

$ver = ''
if ((Get-Content -LiteralPath $target -Raw) -match "\`$Version\s*=\s*'([^']+)'") { $ver = $matches[1] }
Write-Host "SimpoDownloader $ver installed." -ForegroundColor Green
Write-Host ''
Write-Host 'Now just type:' -ForegroundColor Cyan
Write-Host '   simpodl                  (it asks for the folder, then the link)'
Write-Host '   simpodl "<link>"         (downloads into the folder you are in)'
Write-Host '   simpodl help             (all commands)'
Write-Host ''
