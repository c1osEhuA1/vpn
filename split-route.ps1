<#
.SYNOPSIS
    让指定的域名/IP/进程 绕过 TUN 型 VPN，直接走物理网卡。

.DESCRIPTION
    原理：给目标 IP 加 /32 路由指向物理网关。路由表里 /32 比 0.0.0.0/0 更具体，
    所以只有这些 IP 走直连，其余流量继续走 VPN。

    目标来源（会合并）：
      1. -Targets 参数
      2. presets\<名字>.txt（-Preset / -Preset2）
      3. targets.txt
      4. processes.txt（一行一个进程名，抓它们当前连接的对端 IP）
      5. -IncludeProcess 参数

    支持写法：
      api.example.com        普通域名
      *.example.com          自动展开常见子域（www/api/m/chat/app/...）
      1.2.3.4                IP
      # 注释
#>
[CmdletBinding()]
param(
    [string]$Preset,
    [string]$Preset2,
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
    if ($Preset) { $argList += @('-Preset', $Preset) }
    if ($Preset2) { $argList += @('-Preset2', $Preset2) }
    if ($Targets) { $argList += @('-Targets', ($Targets -join ',')) }
    if ($IncludeProcess) { $argList += @('-IncludeProcess', ($IncludeProcess -join ',')) }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

Write-Host "=============================================="
Write-Host "  VPN Split Route — 让指定目标绕过 VPN"
Write-Host "=============================================="
Write-Host ""

# ---------------------------------------------------------------- 读取目标
$wanted = New-Object System.Collections.Generic.List[string]

function Read-ListFile([string]$path) {
    if (-not (Test-Path $path)) { return }
    Get-Content $path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) { $wanted.Add($line) }
    }
}

if ($Targets) { $wanted.AddRange([string[]]$Targets) }

foreach ($p in @($Preset, $Preset2)) {
    if (-not $p) { continue }
    $presetPath = if (Test-Path $p) { $p } else { Join-Path $scriptDir "presets\$p.txt" }
    if (Test-Path $presetPath) {
        Read-ListFile $presetPath
        Write-Host ("已加载预设: " + $presetPath) -ForegroundColor DarkCyan
    } else {
        Write-Host ("[!] 找不到预设: " + $presetPath) -ForegroundColor Yellow
    }
}

Read-ListFile (Join-Path $scriptDir 'targets.txt')

# 进程清单：一行一个进程名
$procNames = New-Object System.Collections.Generic.List[string]
if ($IncludeProcess) { $procNames.AddRange([string[]]$IncludeProcess) }
$procFile = Join-Path $scriptDir 'processes.txt'
if (Test-Path $procFile) {
    Get-Content $procFile -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) { $procNames.Add($line) }
    }
}

if ($wanted.Count -eq 0 -and $procNames.Count -eq 0) {
    Write-Host "[X] 没有任何目标。检查 targets.txt / processes.txt / -Preset。" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

# ---------------------------------------------------------------- 物理网卡
$candidates = Get-NetIPConfiguration | Where-Object {
    $_.IPv4DefaultGateway -and
    $_.InterfaceDescription -notmatch 'VirtNet|TAP|WireGuard|tun|Wintun|OpenVPN|nthlink'
}
if (-not $candidates) {
    Write-Host "[X] 找不到带默认网关的物理网卡（VPN 占满路由了？先断开 VPN 再运行一次）" -ForegroundColor Red
    Get-NetIPConfiguration | Format-Table InterfaceAlias, InterfaceDescription, @{n = 'GW'; e = { $_.IPv4DefaultGateway.NextHop } } -AutoSize
    Read-Host "按回车退出"
    exit 1
}
$nic = $candidates | Select-Object -First 1
$gw = $nic.IPv4DefaultGateway.NextHop
Write-Host ("物理网卡 : {0}" -f $nic.InterfaceAlias) -ForegroundColor Cyan
Write-Host ("网关     : {0}" -f $gw) -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------- 展开域名
$prefixes = @('www', 'api', 'm', 'chat', 'app', 'open', 'platform', 'console', 'login',
              'passport', 'cdn', 'static', 'gateway', 'ws', 'wss', 'ark', 'upload', 'sso')

$hosts = New-Object System.Collections.Generic.HashSet[string]
foreach ($t in $wanted) {
    if ($t -match '^\d{1,3}(\.\d{1,3}){3}$') {
        [void]$hosts.Add($t)
        continue
    }
    if ($t.StartsWith('*.')) {
        $base = $t.Substring(2)
        foreach ($p in $prefixes) { [void]$hosts.Add(($p + '.' + $base)) }
        continue
    }
    [void]$hosts.Add($t)
}

# ---------------------------------------------------------------- 解析
$resolvedIps = New-Object System.Collections.Generic.HashSet[string]
foreach ($h in $hosts) {
    if ($h -match '^\d{1,3}(\.\d{1,3}){3}$') {
        [void]$resolvedIps.Add($h)
        continue
    }
    try {
        [System.Net.Dns]::GetHostAddresses($h) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { [void]$resolvedIps.Add($_.IPAddressToString) }
    } catch {
        # 解析失败静默，最后看总数
    }
}

# ---------------------------------------------------------------- 进程连接
$skippedProc = @()
foreach ($name in $procNames) {
    $procIds = (Get-Process -Name $name -ErrorAction SilentlyContinue).Id
    if (-not $procIds) {
        $skippedProc += $name
        continue
    }
    $before = $resolvedIps.Count
    Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -in $procIds -and $_.RemoteAddress -notmatch '^(127\.|0\.0\.0\.0|::)' } |
        ForEach-Object { [void]$resolvedIps.Add($_.RemoteAddress) }
    Write-Host ("进程 {0}: +{1} 个 IP" -f $name, ($resolvedIps.Count - $before)) -ForegroundColor DarkCyan
}
if ($skippedProc.Count) {
    $shown = $skippedProc | Select-Object -First 4
    $more = if ($skippedProc.Count -gt 4) { " 等 " + $skippedProc.Count + " 个" } else { "" }
    Write-Host ("[i] 没在运行（已跳过）: " + ($shown -join ', ') + $more) -ForegroundColor DarkYellow
}

if ($resolvedIps.Count -eq 0) {
    Write-Host "[X] 一个 IP 都没拿到（域名解析失败？先用 -DryRun 看看）" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

Write-Host ""
Write-Host ("将放行 {0} 个 IP：" -f $resolvedIps.Count)
$resolvedIps | ForEach-Object { Write-Host ("  " + $_) }
Write-Host ""

# ---------------------------------------------------------------- 加路由
$ok = 0
foreach ($ip in $resolvedIps) {
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
    $resolvedIps | Set-Content $stateFile -Encoding ASCII
    Write-Host ""
    Write-Host ("完成：{0}/{1} 条路由已添加。" -f $ok, $resolvedIps.Count)
    Write-Host "撤销请运行 undo-split-route.ps1"
}

Write-Host ""
Read-Host "按回车退出"
