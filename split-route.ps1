<#
.SYNOPSIS
    让指定的域名/IP 绕过 TUN 型 VPN，直接走物理网卡。

.DESCRIPTION
    原理：给目标 IP 加 /32 路由指向物理网关。Windows 路由表里 /32 比 0.0.0.0/0 更具体，
    所以只有这些 IP 走直连，其余流量继续走 VPN。

.PARAMETER Targets
    域名或 IP 列表。不传就读同目录 targets.txt。

.PARAMETER IncludeProcess
    额外放行这些进程当前正在连接的对端 IP（按进程名，例如 "ssh","Code"）。

.PARAMETER DryRun
    只打印将要执行的命令，不修改路由表。

.EXAMPLE
    .\split-route.ps1

.EXAMPLE
    .\split-route.ps1 -Targets "api.example.com","10.0.0.5" -DryRun

.NOTES
    MIT License. 需要管理员权限。
#>
[CmdletBinding()]
param(
    [string[]]$Targets,
    [string[]]$IncludeProcess,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $PSCommandPath

# ---------------------------------------------------------------- 提权
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Host "需要管理员权限，正在申请…" -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Targets) { $argList += @('-Targets', ($Targets -join ',')) }
    if ($IncludeProcess) { $argList += @('-IncludeProcess', ($IncludeProcess -join ',')) }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

Write-Host "=============================================="
Write-Host "  VPN Split Route — 让指定目标绕过 VPN"
Write-Host "=============================================="
Write-Host ""

# ---------------------------------------------------------------- 目标列表
$wanted = New-Object System.Collections.Generic.List[string]
if ($Targets) { $wanted.AddRange([string[]]$Targets) }

$targetsFile = Join-Path $scriptDir 'targets.txt'
if (Test-Path $targetsFile) {
    Get-Content $targetsFile -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) { $wanted.Add($line) }
    }
}

if ($wanted.Count -eq 0) {
    Write-Host "[X] 没有任何目标。请写 targets.txt，或用 -Targets 参数。" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

# ---------------------------------------------------------------- 物理网卡
$candidates = Get-NetIPConfiguration | Where-Object {
    $_.IPv4DefaultGateway -and
    $_.InterfaceDescription -notmatch 'VirtNet|TAP|WireGuard|tun|Wintun|OpenVPN|nthlink'
}
if (-not $candidates) {
    Write-Host "[X] 找不到带默认网关的物理网卡（VPN 可能占了全部路由）。先断开 VPN 再运行一次。" -ForegroundColor Red
    Get-NetIPConfiguration | Format-Table InterfaceAlias, InterfaceDescription, @{n = 'GW'; e = { $_.IPv4DefaultGateway.NextHop } } -AutoSize
    Read-Host "按回车退出"
    exit 1
}
$nic = $candidates | Select-Object -First 1
$gw = $nic.IPv4DefaultGateway.NextHop
Write-Host ("物理网卡 : {0}" -f $nic.InterfaceAlias) -ForegroundColor Cyan
Write-Host ("网关     : {0}" -f $gw) -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------- 解析 IP
$ips = New-Object System.Collections.Generic.HashSet[string]
foreach ($t in $wanted) {
    if ($t -match '^\d{1,3}(\.\d{1,3}){3}$') {
        [void]$ips.Add($t)
        continue
    }
    try {
        [System.Net.Dns]::GetHostAddresses($t) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { [void]$ips.Add($_.IPAddressToString) }
    } catch {
        Write-Host ("  [!] 解析失败: {0}" -f $t) -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------- 进程现有连接
if ($IncludeProcess) {
    foreach ($name in $IncludeProcess) {
        $procIds = (Get-Process -Name $name -ErrorAction SilentlyContinue).Id
        if (-not $procIds) { continue }
        Get-NetTCPConnection -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -in $procIds -and $_.RemoteAddress -notmatch '^(127\.|0\.0\.0\.0|::)' } |
            ForEach-Object { [void]$ips.Add($_.RemoteAddress) }
    }
}

if ($ips.Count -eq 0) {
    Write-Host "[X] 一个 IP 都没解析到。" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

Write-Host ("将放行 {0} 个 IP：" -f $ips.Count)
$ips | ForEach-Object { Write-Host ("  " + $_) }
Write-Host ""

# ---------------------------------------------------------------- 加路由
$ok = 0
foreach ($ip in $ips) {
    if ($DryRun) {
        Write-Host ("  [DRY] route add {0} mask 255.255.255.255 {1} metric 1" -f $ip, $gw) -ForegroundColor DarkCyan
        continue
    }
    & route delete $ip 2>$null | Out-Null
    $out = & route add $ip mask 255.255.255.255 $gw metric 1 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  [OK]   {0} -> {1}" -f $ip, $gw) -ForegroundColor Green
        $ok++
    } else {
        Write-Host ("  [FAIL] {0} : {1}" -f $ip, ($out -join ' ')) -ForegroundColor Red
    }
}

if (-not $DryRun) {
    $stateFile = Join-Path $scriptDir 'split-route-state.txt'
    $ips | Set-Content $stateFile -Encoding ASCII
    Write-Host ""
    Write-Host ("完成：{0}/{1} 条路由已添加。" -f $ok, $ips.Count)
    Write-Host "撤销请运行 undo-split-route.ps1"
}

Write-Host ""
Read-Host "按回车退出"
