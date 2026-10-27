# VPN Split Route

**Let specific domains/IPs bypass a TUN VPN on Windows — no VPN-client settings needed.**

Sometimes you need a TUN-based VPN running for everything else, but one service must stay on the
direct connection (a corporate API, a long-lived remote session, a regional service). Many minimal
VPN clients have no split-tunnelling option at all — and connecting them can even kill sessions
that are already open.

This tool adds a `/32` route for the target IPs through the **physical** gateway. Windows prefers
the most specific route, so only those targets go direct while everything else keeps using the VPN.

```
0.0.0.0/0        -> VPN gateway   (metric 0)
203.0.113.7/32   -> LAN gateway   (metric 1)   <- wins for that single IP
```

---

## 中文说明

**让指定的域名 / IP 绕过 TUN 型 VPN 走直连，不用改 VPN 客户端设置。**

很多轻量 VPN 客户端（nthLink、或任何 TUN 模式客户端）会抢走默认路由 `0.0.0.0/0`，
结果所有流量都进隧道——包括你不想走 VPN 的国内服务、公司内网、本地 API，
甚至连正在运行的远程会话都会当场断掉。这些客户端通常**没有分流设置**，你也改不了它。

本工具给目标 IP 加一条 `/32` 路由指向**物理网卡网关**。Windows 路由表里更具体的路由优先，
于是只有这些 IP 走直连，其它流量照常走 VPN。

---

## Usage / 用法

```powershell
# 1. Connect your VPN first / 先连上 VPN
# 2. Run as administrator (the .bat launchers self-elevate)
.\split-route.ps1

# Undo / 撤销
.\undo-split-route.ps1
```

Targets live in `targets.txt` (one domain or IP per line, `#` for comments):

```text
api.deepseek.com
chat.deepseek.com
192.168.1.10
```


### Presets / 预设

presets/ 里放好了常用目标清单，直接指定名字即可：

`powershell
.\split-route.ps1 -Preset ai-all      # 全部国产 AI（DeepSeek / 豆包 / Kimi / 通义 / 文心 / 智谱 / 星火 / 混元 / MiniMax / 阶跃 / 百川 / 零一）
.\split-route.ps1 -Preset deepseek    # 只放行 DeepSeek
`

或者双击 放行全部国产AI.bat（等于 -Preset ai-all）。

想加自己的服务：在 presets/ 里新建一个 xxx.txt，一行一个域名，然后 -Preset xxx。


### Coverage / 覆盖范围

开箱覆盖 **网页 + 桌面客户端 + 中转站**：

```powershell
.\split-route.ps1 -Preset ai-all -Preset2 relay   # 或双击「全部放行.bat」
```

| 来源 | 怎么处理 |
|---|---|
| 网页版 AI（DeepSeek / 豆包 / Kimi / 通义 / 文心 / 智谱 / 星火 / 混元 / MiniMax / 阶跃 / 百川 / 零一） | `presets/ai-all.txt` 里的域名 |
| 桌面客户端 | `processes.txt` 里的进程名 → 抓它当前连接的 IP（客户端域名经常变，按进程最稳） |
| 中转站 / 自建网关（OneAPI、NewAPI、聚合客户端） | `presets/relay.txt` 里的域名 + 你自己的域名写进 targets.txt |

### Wildcard / 通配

```text
*.your-domain.com
```

会自动展开成 `www.` / `api.` / `m.` / `chat.` / `app.` / `open.` / `platform.` / `console.` /
`login.` / `passport.` / `cdn.` / `static.` / `gateway.` / `ws.` / `wss.` / `ark.` / `upload.` / `sso.`
共 18 个常见子域，能覆盖大部分“前端 + 接口分开”的服务。

### Parameters / 参数

```powershell
.\split-route.ps1                              # read targets.txt
.\split-route.ps1 -Targets "a.com","1.2.3.4"   # ad-hoc targets
.\split-route.ps1 -IncludeProcess "ssh","Code" # also allow these processes' current peers
.\split-route.ps1 -DryRun                      # print only, change nothing
```

What it does:

1. Finds the **physical** NIC and gateway (skips `VirtNet` / `TAP` / `WireGuard` / `tun` / `Wintun` / `OpenVPN`)
2. Resolves every host in `targets.txt`
3. Optionally collects the current peers of the given processes
4. Adds `/32` routes with `metric 1`
5. Records what it added in `split-route-state.txt` so undo is precise

## When it works / 适用性

| Scenario | Works? |
|---|---|
| TUN / route-based VPN (nthLink, WireGuard, Clash TUN, sing-box TUN) | Yes |
| System-proxy / HTTP-proxy VPN | Not needed (proxy rules already handle it) |
| PPTP / L2TP and similar | Usually yes, if it hijacks the default route |
| Need to exempt a whole *program* | Only its current peer IPs; re-run when the IP changes |

## Limitations / 已知限制

- Routes are **not persistent** — a reboot clears them (intentional: you can't forget it)
- CDN-hosted domains resolve to several IPs; all of them are added
- If the VPN also breaks DNS, resolution fails — connect the VPN afterwards, or put raw IPs in `targets.txt`
- IPv4 only

## Why not use… / 为什么不用别的

| Alternative | Why not |
|---|---|
| Clash / Mihomo rules | Clash-family clients only |
| sing-box `process_name` | sing-box only |
| WireGuard `AllowedIPs` | Config-only, WireGuard-only |
| ForceBindIP | 2007-era tool, per-process only, no host granularity |

## License

MIT — see [LICENSE](LICENSE).
