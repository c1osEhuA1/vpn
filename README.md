# VPN Split Route

**Let chosen websites / apps bypass a TUN VPN on Windows.**

For the case where your VPN hijacks the default route and you need a few services to stay on the
direct connection. No VPN-client settings required.

```
0.0.0.0/0        -> VPN gateway    (everything else goes through the tunnel)
203.0.113.7/32   -> LAN gateway    (these targets go direct)
```

---

## 中文说明

**让指定的网站 / 软件绕过 TUN 型 VPN，走直连。**

适用场景：VPN 一连就抢走默认路由，导致国内服务变慢、内网连不上、正在跑的远程会话断开，
而你这个 VPN 客户端又没有分流设置。

原理：给目标 IP 加一条 `/32` 路由指向物理网关。Windows 路由表里更具体的优先命中，
所以只有这些 IP 直连，其它流量照常走 VPN。

> ⚠️ 这不是翻墙工具。它只负责“让某些东西不走 VPN”。

---

## 只有一个入口、一个配置

```
一键.bat          ← 双击它，按菜单选
放行清单.txt      ← 唯一要改的文件
split-route.ps1   ← 引擎，不用管
```

### 一键.bat 菜单

```
1. 放行一次      挂 VPN 之前点一次
2. 放行 + 守护   VPN 会重置路由时用，窗口留着别关
3. 撤销          删掉所有规则
4. 看会放行什么   只预览，不动系统
```

### 放行清单.txt 怎么写

```text
api.example.com      域名
*.example.com        通配：展开 18 个常见子域
1.2.3.4              IP
proc:Doubao          进程：抓它当前连接的对端 IP（客户端类最准）
# 注释
```

默认已写好：国产 AI（DeepSeek / 豆包 / Kimi / 通义 / 文心 / 智谱 / 星火 / 混元 / MiniMax /
阶跃 / 百川 / 零一）、几个中转站、常见 AI 客户端进程名。

---

## Quick start

```text
1. 双击 一键.bat
2. 选 2（放行 + 守护，推荐）或 1（放行一次）
3. UAC 点「是」
```

推荐顺序：**先跑 一键.bat 选 2，再连 VPN** —— VPN 重置路由时会被 5 秒内补回。

## 命令行（可选）

```powershell
.\split-route.ps1            # 放行一次
.\split-route.ps1 -Watch     # 放行 + 守护
.\split-route.ps1 -Undo      # 撤销
.\split-route.ps1 -DryRun    # 只预览
.\split-route.ps1 -ShowVersion
```

## 限制

- Windows 专用，需要管理员权限（改路由表）
- 只处理 IPv4
- 路由不持久，重启即失效（故意如此）
- 只对 TUN / 路由型 VPN 有意义；系统代理型 VPN 不需要
- 少数 VPN 在驱动层拦截，`/32` 路由对它无效 —— 守护模式也压不住

## Changelog

### v1.4.0

- 修：`一键.bat` 之前是 UTF-8，中文 Windows 下会乱码 → 改成 GBK(936)
- 修：菜单按空回车会无限循环 → 加空输入退出
- 修：`set /p` 读到输入结束不清空变量 → 先 `set "ch="`
- 打包：桌面版 zip 只含 7 个文件，不含运行时文件

### v1.3.0
- 大简化：**一个 一键.bat + 一个 放行清单.txt**，删掉一堆分散启动器和预设目录
- 配置支持 `proc:` 行，域名和进程写在同一个文件

### v1.2.0
- 新增 `-Watch` 守护模式（VPN 重置路由后自动补回）

### v1.1.0
- 预设机制、通配子域、按进程抓 IP

### v1.0.0
- 首个版本

## License

MIT — see [LICENSE](LICENSE).
