# faketcp — Mimic 管理脚本

单文件 POSIX `sh` 交互脚本，用于安装、配置、维护
[hack3ric/mimic](https://github.com/hack3ric/mimic)（基于 eBPF 的 UDP↔TCP 混淆器）。

支持 **Debian / Ubuntu / Alpine / OpenWrt / ImmortalWrt**，自动识别系统、架构、
服务管理器与默认网卡。安装的服务开机自启，崩溃自动重启。

> 本脚本只是 mimic 的**部署与配置外壳**，不修改 mimic 本身。
> 协议原理、防火墙要求、MTU 调整请以
> [官方文档](https://github.com/hack3ric/mimic/tree/master/docs) 为准。

## 快速开始

```sh
curl -fsSL https://raw.githubusercontent.com/fa1nes/faketcp/main/mimic.sh -o mimic.sh \
  && chmod +x mimic.sh && sudo ./mimic.sh
```

国内加速（GitHub 拉不动时）：

```sh
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/fa1nes/faketcp/main/mimic.sh \
  -o mimic.sh && chmod +x mimic.sh && sudo ./mimic.sh
```

脚本内部下载二进制默认也走镜像 `https://ghfast.top`，可用环境变量调整：

```sh
GHPROXY=https://gh-proxy.com ./mimic.sh   # 换镜像
GHPROXY= ./mimic.sh                       # 关镜像，直连 GitHub
```

安装后可在任意目录输入 `faketcp` 或 `mimic-manager` 再次进入菜单。

## 菜单

```
 1) 安装 / 修复        2) 配置服务端
 3) 配置客户端         4) 高级选项
 5) 查看配置           6) 部署自检
 7) 启动               8) 停止
 9) 重启              10) 状态
11) 更新              12) 完全卸载
 0) 退出
```

- **服务端**：只需输入 UDP 端口。生成通配过滤器
  `local=0.0.0.0:PORT` 与 `local=[::]:PORT`，mimic 会通过 rtnetlink
  动态跟踪本机地址变化——**PPPoE 重拨、DHCP 换址后无需改配置**。
- **客户端**：填服务端的 IP 或域名 + 端口。域名原样写入配置，由 mimic
  自己 `getaddrinfo` 解析（`mimic show` 里会显示 `resolved from <域名>`）。
- **高级选项**：XDP 模式、日志级别、per-filter 的 handshake / keepalive 参数。
- **部署自检**：调用官方 `mimic run --check`，完整走一遍
  解析配置 → 加载 BPF → 挂载 TC/XDP → 灌 filter，然后退出。
  因为要独占锁文件，**需先停止服务**。

配置保存在 `/etc/mimic/`：

| 文件 | 内容 |
| --- | --- |
| `iface` | 绑定的网卡名 |
| `server.ports` | 服务端 UDP 端口，一行一个 |
| `client.list` | 客户端远端，`主机 端口` 一行一条 |
| `options` | XDP 模式、日志级别、连接参数 |
| `<iface>.conf` | **由上述文件生成**，交给 mimic 的实际配置 |

`<iface>.conf` 每次改配置都会重新生成，手改会被覆盖。要固化自定义内容请直接
用 mimic 原生配置并停用本脚本。

## 与官方包的关系

脚本**优先使用官方渠道**，官方覆盖不到时才回退：

| 系统 | 第一优先 | 回退 1 | 回退 2 |
| --- | --- | --- | --- |
| Debian / Ubuntu | 官方 release deb（`mimic` + `mimic-dkms`，含 DKMS 内核模块） | 发行版仓库的 `mimic` | 本仓库预编译 → 本地编译 |
| Alpine | 本地编译（可同时产出 kfunc 内核模块） | 本仓库预编译 | — |
| OpenWrt | 软件源 `mimic` + `kmod-mimic` | 本仓库 `.ipk`/`.apk`（上游 SDK 交叉编译） | 裸二进制 |

注意几处与官方一致的细节：

- 官方 deb 把二进制装在 **`/usr/sbin/mimic`**，OpenWrt 包在 **`/usr/bin/mimic`**。
  脚本每次都动态定位，不写死路径。
- 检测到官方 `mimic@.service` 时**直接复用它**（`Type=notify` /
  `Requires=modprobe@mimic.service` / `RuntimeDirectory` / `ProtectSystem=strict`），
  只在缺内核模块时补一条 `ethtool -K %i tx off` 的 `ExecStartPre`。
  官方单元的 `CapabilityBoundingSet` 不含 `CAP_SYS_MODULE`，所以
  **drop-in 里不会放 `modprobe`**——放了也必然失败。
- 没有官方单元时才写自己的 `faketcp@<iface>.service`，字段对齐官方
  （`Type=notify`、`Restart=on-failure`、`RuntimeDirectory=mimic`）。

## 校验和 hack

mimic 把 UDP 改成 TCP 时无法在 eBPF 里修正 `skb->csum_offset`，需要内核模块配合，
详见官方 [checksum-hacks.md](https://github.com/hack3ric/mimic/blob/master/docs/checksum-hacks.md)。

- **有内核模块**（kfunc）：满速，Debian 走 DKMS、Alpine 走本地编译。
- **无内核模块**：脚本自动加 `ethtool -K <iface> tx off` 关闭 TX 校验和卸载。
  Realtek / MediaTek 网卡驱动本就不使用 `csum_offset`，**不需要**校验和 hack。

## 部署要点

- mimic 给每个 UDP 包**增加 12 字节**。隧道协议请把 MTU 调低 12
  （例如 WireGuard over IPv6 从 1420 改 1408）。
- 防火墙需**同时按 TCP 和 UDP 放行**：TC eBPF 在 netfilter output 之后，
  netfilter 看到的是 UDP；XDP 在 input 之前，netfilter 看到的是 TCP。
- Intel `igc` / `e1000` / `igb` 或某些虚拟机的 `virtio_net` 用 XDP native
  模式可能丢包，在「高级选项」里把 XDP 模式改成 `skb`。

## 预编译产物

本仓库 GitHub Actions 每日构建，作为官方渠道的兜底：

| tag | 内容 | 架构 |
| --- | --- | --- |
| `debian` | `mimic-debian-<arch>` | x86_64 / aarch64 / armv7 |
| `alpine` | `mimic-alpine-<arch>` | x86_64 / aarch64 / armv7 |
| `openwrt` | `mimic-openwrt-<owrt_arch>{,.ipk,.apk}` | x86_64 / aarch64_generic / arm_cortex-a7 / mipsel_24kc |

编译参数与官方要求对齐：kprobe 校验和 hack 必配 `STRIP_BTF_EXT=1`；
Debian 用 `STATIC_EXCEPT_LIBC=1`（**不能全静态，否则 glibc 的 `getaddrinfo` 会失效**）；
Alpine 用 `STATIC=1`（musl 无此问题）；OpenWrt 直接跑上游 `openwrt` 分支的
`net/mimic/Makefile`，参数由上游维护。

## 卸载

菜单 12，一次确认后清除脚本安装的全部内容（不改动防火墙及其他配置）。
