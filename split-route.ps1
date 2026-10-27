<#
    VPN Split Route — 让指定网站/软件绕过 TUN 型 VPN 走直连

    只有一个配置：放行清单.txt
        api.example.com       域名
        *.example.com         通配（展开常见子域）
        1.2.3.4               IP
        proc:Doubao           进程（抓它当前连接的 IP）

    一般不用直接调这个脚本，双击「一键.bat」即可。
#>
[CmdletBinding()]
param(
    [switch]$Undo,
    [switch]$Watch,
    [int]$WatchSec = 5,
    [switch]$DryRun,
    [switch]$ShowVersion
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $PSCommandPath
$ScriptVersion = '1.4.0'
if ($ShowVersion) { Write-Host $ScriptVersion; exit 0 }

$listFile = Join-Path $scriptDir '放行清单.txt'
$stateFile = Join-Path $scriptDir 'split-route-state.txt'

# ---------------------------------------------------------------- 撤销
if ($Undo) {
    $isAdminU = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdminU) {
        Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Undo'
        exit
    }
    Write-Host "正在撤销…" -ForegroundColor Yellow
    $ips = @()
    if (Test-Path $stateFile) {
        $ips = Get-Content $stateFile | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }
    }
    foreach ($ip in $ips) {
        & route delete $ip 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host ("  已删除 {0}" -f $ip) -ForegroundColor Green }
    }
    if (Test-Path $stateFile) { Remove-Item $stateFile -Force -EA SilentlyContinue }
    Write-Host "完成。"
    exit 0
}

# ---------------------------------------------------------------- 提权
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Host "需要管理员权限，正在申请…" -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Watch) { $argList += @('-Watch', '-WatchSec', $WatchSec) }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

Write-Host "=============================================="
Write-Host ("  VPN Split Route  v" + $ScriptVersion)
Write-Host "=============================================="
Write-Host ""

if (-not (Test-Path $listFile)) {
    Write-Host "[X] 找不到 放行清单.txt" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

# ---------------------------------------------------------------- 读清单
$hosts = New-Object System.Collections.Generic.HashSet[string]
$procs = New-Object System.Collections.Generic.List[string]

Get-Content $listFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#')) { return }
    if ($line.StartsWith('proc:')) {
        $procs.Add($line.Substring(5).Trim())
    } else {
        [void]$hosts.Add($line)
    }
}

# ---------------------------------------------------------------- 物理网卡
$nic = Get-NetIPConfiguration | Where-Object {
    $_.IPv4DefaultGateway -and
    $_.InterfaceDescription -notmatch 'VirtNet|TAP|WireGuard|tun|Wintun|OpenVPN|nthlink'
} | Select-Object -First 1

if (-not $nic) {
    Write-Host "[X] 找不到物理网卡（VPN 占满路由？先断开 VPN 再跑）" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}
$gw = $nic.IPv4DefaultGateway.NextHop
Write-Host ("物理网卡 : {0}    网关 : {1}" -f $nic.InterfaceAlias, $gw) -ForegroundColor Cyan

# ---------------------------------------------------------------- 解析
$prefixes = @('www','api','m','chat','app','open','platform','console','login',
              'passport','cdn','static','gateway','ws','wss','ark','upload','sso')
$expanded = New-Object System.Collections.Generic.HashSet[string]
foreach ($h in $hosts) {
    if ($h.StartsWith('*.')) {
        foreach ($p in $prefixes) { [void]$expanded.Add($p + '.' + $h.Substring(2)) }
    } else { [void]$expanded.Add($h) }
}

$ips = New-Object System.Collections.Generic.HashSet[string]
foreach ($h in $expanded) {
    if ($h -match '^\d{1,3}(\.\d{1,3}){3}$') { [void]$ips.Add($h); continue }
    try {
        [System.Net.Dns]::GetHostAddresses($h) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { [void]$ips.Add($_.IPAddressToString) }
    } catch { }
}

foreach ($name in $procs) {
    $procIds = (Get-Process -Name $name -ErrorAction SilentlyContinue).Id
    if (-not $procIds) { continue }
    Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -in $procIds -and $_.RemoteAddress -notmatch '^(127\.|0\.0\.0\.0|::)' } |
        ForEach-Object { [void]$ips.Add($_.RemoteAddress) }
}

if ($ips.Count -eq 0) {
    Write-Host "[X] 一个 IP 都没拿到（域名解析失败？）" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

Write-Host ("放行 {0} 个 IP" -f $ips.Count) -ForegroundColor Cyan

# ---------------------------------------------------------------- 加路由
$ok = 0
foreach ($ip in $ips) {
    if ($DryRun) { Write-Host ("  [DRY] {0}" -f $ip) -ForegroundColor DarkCyan; continue }
    & route delete $ip 2>$null | Out-Null
    & route add $ip mask 255.255.255.255 $gw metric 1 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $ok++ }
}
if (-not $DryRun) {
    $ips | Set-Content $stateFile -Encoding ASCII
    Write-Host ("完成：{0}/{1} 条路由" -f $ok, $ips.Count) -ForegroundColor Green
}

# ---------------------------------------------------------------- 守护
if ($Watch -and -not $DryRun) {
    Write-Host ""
    Write-Host ("守护中：每 {0} 秒检查，被 VPN 冲掉自动补回（Ctrl+C 停止）" -f $WatchSec) -ForegroundColor Cyan
    while ($true) {
        Start-Sleep -Seconds $WatchSec
        foreach ($ip in $ips) {
            if (-not (Get-NetRoute -DestinationPrefix ("{0}/32" -f $ip) -ErrorAction SilentlyContinue)) {
                & route add $ip mask 255.255.255.255 $gw metric 1 2>$null | Out-Null
                Write-Host ("[{0}] 补回 {1}" -f (Get-Date -Format HH:mm:ss), $ip) -ForegroundColor Green
            }
        }
    }
}
