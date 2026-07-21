# mimic.sh — Mimic (faketcp) 安装与配置管理脚本

一个用 `#!/bin/sh` 编写的极简管理脚本，用于在自己的 Linux 设备上安装、配置和维护
[hack3ric/mimic](https://github.com/hack3ric/mimic)。

Mimic 是一个基于 eBPF 的 **UDP↔TCP 混淆器（faketcp）**，把 UDP 流量在内核 TC/XDP
路径上伪装成 TCP，用来绕过针对 UDP 的 QoS 限速和端口封锁。本脚本只负责“安装 + 生成配置 +
托管服务”，真正的 `mimic` 二进制始终来自官方，不会被覆盖。

> ⚠️ 仅供管理你自己的设备。脚本不会修改防火墙或任何其他软件的配置。

## 特性

- **一个交互式中文菜单**：安装 / 配置服务端 / 配置客户端 / 查看配置 / 启动 / 停止 / 重启 / 状态 / 更新 / 完全卸载
- **自动识别**系统、CPU 架构、默认网卡、服务管理器
- **多发行版**：Debian、Ubuntu、Alpine、OpenWrt、ImmortalWrt
- **服务端**：自动探测本机公网 IPv4/IPv6，只问你 UDP 端口
- **客户端**：可添加 / 查看 / 删除多个远端 IP 或域名及端口（域名在生成配置时解析为 IP）
- **彩色输出**，非终端或设置 `NO_COLOR` 时自动关闭
- 配置统一保存在 `/etc/mimic/`，与官方 systemd 服务 `mimic@<iface>` 天然兼容

## 各平台安装方式

| 系统 | 安装来源 |
| --- | --- |
| Debian / Ubuntu | 下载官方 GitHub Release 的 `mimic` + `mimic-dkms` deb 包（按发行版代号与架构匹配） |
| Alpine | 按官方文档 `apk` 安装依赖后 `git clone` + `make` 源码编译 |
| OpenWrt / ImmortalWrt | `opkg install kmod-mimic mimic`，仅安装与当前内核匹配的包，**绝不使用 `--force`** |

## 快速开始

```sh
# 1. 把 mimic.sh 传到目标 Linux 设备
# 2. 赋予执行权限并以 root 运行
chmod +x mimic.sh
sudo ./mimic.sh          # 或  sudo sh mimic.sh
```

安装完成后，脚本会把自身复制为 `/usr/bin/mimic-manager`，并建立软链 `faketcp`。
之后在任意目录直接输入即可再次进入菜单：

```sh
faketcp
# 或
mimic-manager
```

## 使用流程

1. **`1) 安装`** — 自动识别环境并安装 mimic，同时注册管理入口与服务。
2. **`2) 配置服务端`** — 脚本自动获取公网 IPv4/IPv6，你只需输入 UDP 端口，
   生成 `filter = local=<公网IP>:<端口>`。
3. **`3) 配置客户端`** — 进入子菜单，增/查/删多个远端（IP 或域名）+ 端口，
   生成 `filter = remote=<对端>:<端口>`。
4. **`4) 查看配置`** — 显示当前网卡、服务端/客户端过滤器及最终生成的 `.conf`。
5. **`5`~`8`** — 启动 / 停止 / 重启 / 查看状态。
6. **`9) 更新`** — 先比较本地与最新版本，有新版本才询问 `y/N`。
7. **`10) 完全卸载`** — 一次 `y/N` 确认后，删除脚本安装的全部内容（软件包、
   `/etc/mimic/`、服务、管理入口），**不触碰防火墙**。

## 配置文件

所有状态都存放在 `/etc/mimic/`：

| 文件 | 说明 |
| --- | --- |
| `iface` | 当前使用的网卡名 |
| `version` | 已安装的版本号 |
| `server.filters` | 服务端 `local=` 过滤器 |
| `client.list` | 客户端远端列表（`主机 端口` 每行一条） |
| `<iface>.conf` | 由上述文件自动生成、供 mimic 读取的最终配置 |

生成的 `<iface>.conf` 与官方 systemd 服务 `mimic@<iface>` 使用同一路径；在
Alpine（OpenRC）与 OpenWrt（procd）上，脚本会创建名为 `faketcp` 的服务运行
`mimic run -F /etc/mimic/<iface>.conf <iface>`。

## 防火墙提示

Mimic 的流量在防火墙里同时表现为 **TCP 与 UDP**（出站被 netfilter 视为 UDP，
入站的控制包为真实 TCP）。若设备启用了严格防火墙，请自行放行对应端口——本脚本
按设计不会修改任何防火墙规则。

## 环境要求

- Linux 内核 **≥ 6.1** 且启用基本 BPF 支持（多数桌面/服务器发行版默认满足）
- `curl` 或 `wget`
- root 权限

## 许可

管理脚本随上游一同以 **GPL-2.0-only** 提供。上游项目：<https://github.com/hack3ric/mimic>
