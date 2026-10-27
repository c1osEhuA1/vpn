<#
.SYNOPSIS
    撤销 split-route.ps1 添加的路由。

.NOTES
    MIT License. 需要管理员权限。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $PSCommandPath

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    exit
}

Write-Host "正在删除专用路由…" -ForegroundColor Yellow

$ips = @()
$stateFile = Join-Path $scriptDir 'split-route-state.txt'
if (Test-Path $stateFile) {
    $ips = Get-Content $stateFile | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }
}

$targetsFile = Join-Path $scriptDir 'targets.txt'
if (Test-Path $targetsFile) {
    Get-Content $targetsFile -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^\d{1,3}(\.\d{1,3}){3}$') {
                if ($line -notin $ips) { $ips += $line }
            } else {
                try {
                    [System.Net.Dns]::GetHostAddresses($line) |
                        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                        ForEach-Object { if ($_.IPAddressToString -notin $ips) { $ips += $_.IPAddressToString } }
                } catch { }
            }
        }
    }
}

if ($ips.Count -eq 0) {
    Write-Host "没有可删除的记录。" -ForegroundColor DarkGray
} else {
    foreach ($ip in $ips) {
        & route delete $ip 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host ("  已删除 {0}" -f $ip) -ForegroundColor Green
        } else {
            Write-Host ("  跳过 {0}" -f $ip) -ForegroundColor DarkGray
        }
    }
}

if (Test-Path $stateFile) { Remove-Item $stateFile -Force -EA SilentlyContinue }
Write-Host ""
Write-Host "完成。"
Read-Host "按回车退出"
