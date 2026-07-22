# faketcp — Mimic 管理脚本

`#!/bin/sh` 编写的极简交互脚本，用于安装、配置、维护
[hack3ric/mimic](https://github.com/hack3ric/mimic)（基于 eBPF 的 UDP↔TCP 混淆器）。

支持 **Debian / Ubuntu / Alpine / OpenWrt / ImmortalWrt**，自动识别系统、架构、
默认网卡和服务管理器；配置服务端时自动获取公网 IP、只问 UDP 端口。服务安装后
**开机自启**，并在崩溃时自动重启。

## 快速开始

```sh
# 下载 + 赋权 + 运行（root）
curl -fsSL https://raw.githubusercontent.com/fa1nes/faketcp/main/mimic.sh -o mimic.sh && chmod +x mimic.sh && sudo ./mimic.sh
```

### 国内加速（GitHub 拉不动时用镜像）

脚本下载用镜像：

```sh
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/fa1nes/faketcp/main/mimic.sh -o mimic.sh && chmod +x mimic.sh && sudo ./mimic.sh
```

脚本内部下载二进制默认已走镜像 `https://ghfast.top`。可用环境变量切换或关闭：

```sh
# 换其它镜像
GHPROXY=https://gh-proxy.com ./mimic.sh
# 关闭镜像，直连 GitHub
GHPROXY= ./mimic.sh
```

安装后可在任意目录直接输入 `faketcp` 或 `mimic-manager` 再次进入菜单。

## 菜单

```
 1) 安装         2) 配置服务端   3) 配置客户端
 4) 查看配置     5) 启动         6) 停止
 7) 重启         8) 状态         9) 更新
10) 完全卸载     0) 退出
```

- **服务端**：自动探测公网 IPv4/IPv6，输入 UDP 端口即可。
- **客户端**：增/查/删多个远端 IP 或域名 + 端口。
- **启动**：同时注册开机自启（systemd `enable` / OpenRC `rc-update` / procd `enable`）。
- **更新**：先比对版本，有新版才询问。
- **卸载**：一次确认后清除脚本安装的全部内容。

服务持久化运行、开机自启，崩溃自动重启（systemd `Restart=always`、OpenRC
`supervise-daemon`、procd `respawn`）。配置保存在 `/etc/mimic/`，与官方 systemd
服务 `mimic@<iface>` 兼容。
