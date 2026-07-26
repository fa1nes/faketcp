#!/bin/sh
# faketcp — hack3ric/mimic 管理脚本
#
# 设计约束：
#   * 纯 POSIX sh，需可在 busybox ash（OpenWrt）与 musl ash（Alpine）下运行
#   * 与官方包共存：官方 deb 把二进制装在 /usr/sbin/mimic，OpenWrt 包在 /usr/bin/mimic，
#     因此全程使用 locate_mimic() 动态定位，不写死路径
#   * 不重复 mimic 自己已经做好的事（运行时目录创建、陈旧锁自愈、域名解析、
#     通配地址的 rtnetlink 动态跟踪）
set -u

FAKETCP_VER="2.0.0"
UPSTREAM="hack3ric/mimic"
UPSTREAM_API="https://api.github.com/repos/$UPSTREAM"
UPSTREAM_GIT="https://github.com/$UPSTREAM"
RAW_SELF="https://raw.githubusercontent.com/fa1nes/faketcp/main/mimic.sh"
FALLBACK_REL="https://github.com/fa1nes/faketcp/releases/download"
GHPROXY="${GHPROXY-https://ghfast.top}"

CFGDIR="/etc/mimic"
SRV_PORTS="$CFGDIR/server.ports"
CLI_LIST="$CFGDIR/client.list"
OPTFILE="$CFGDIR/options"
SELF="/usr/bin/mimic-manager"

# ---------------------------------------------------------------- 输出

E="$(printf '\033')"
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R="$E[0m"; B="$E[1m"; RED="$E[31m"; GRN="$E[32m"; YLW="$E[33m"
  BLU="$E[34m"; MAG="$E[35m"; CYN="$E[36m"; GRY="$E[90m"
else
  R= B= RED= GRN= YLW= BLU= MAG= CYN= GRY=
fi
ok()    { printf "%s✓ %s%s\n" "$GRN" "$*" "$R"; }
info()  { printf "%s» %s%s\n" "$CYN" "$*" "$R"; }
warn()  { printf "%s! %s%s\n" "$YLW" "$*" "$R"; }
err()   { printf "%s✗ %s%s\n" "$RED" "$*" "$R" >&2; }
sect()  { printf "%s%s── %s ──%s\n" "$B" "$MAG" "$*" "$R"; }
cls()   { [ -t 1 ] && printf '%s[H%s[2J' "$E" "$E"; }
pause() { printf "\n%s按回车继续...%s" "$GRY" "$R"; read -r _ || true; }
die()   { err "错误: $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 root 运行"

# ---------------------------------------------------------------- 下载

if command -v curl >/dev/null 2>&1; then
  dl() { curl -fsSL --connect-timeout 10 --retry 2 "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  # OpenWrt 的 wget 通常是 busybox/uclient-fetch，只有 -q -T -O，没有 -t
  dl() { wget -q -T 15 -O "$2" "$1"; }
else
  die "需要 curl 或 wget"
fi

# 经镜像下载 GitHub 资源，失败则直连。任一路径产出空文件都视为失败。
dlgh() {
  if [ -n "$GHPROXY" ]; then
    dl "${GHPROXY%/}/$1" "$2" && [ -s "$2" ] && return 0
  fi
  rm -f "$2"
  dl "$1" "$2" && [ -s "$2" ]
}

# ---------------------------------------------------------------- 平台探测

OSID=unknown; OSLIKE=""; CODENAME=""; PRETTY=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OSID="${ID:-unknown}"; OSLIKE="${ID_LIKE:-}"
  CODENAME="${VERSION_CODENAME:-}"; PRETTY="${PRETTY_NAME:-$OSID}"
fi

case "$OSID" in
  debian|ubuntu|raspbian|devuan|linuxmint|pop) FAMILY=deb ;;
  alpine)                                      FAMILY=alpine ;;
  openwrt|immortalwrt|lede)                    FAMILY=owrt ;;
  *)
    case " $OSLIKE " in
      *" openwrt "*)             FAMILY=owrt ;;
      *" alpine "*)              FAMILY=alpine ;;
      *" debian "*|*" ubuntu "*) FAMILY=deb ;;
      *)                         FAMILY=unknown ;;
    esac ;;
esac
[ "$FAMILY" = unknown ] && die "不支持的系统: ${PRETTY:-$OSID}（支持 Debian/Ubuntu、Alpine、OpenWrt/ImmortalWrt）"

# 按实际存在的管理器判断，而不是按发行版猜——容器里的 Debian 常常没有 systemd
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  INIT=systemd
elif [ -x /sbin/procd ] || { [ -f /etc/rc.common ] && command -v ubus >/dev/null 2>&1; }; then
  INIT=procd
elif command -v rc-service >/dev/null 2>&1; then
  INIT=openrc
elif command -v systemctl >/dev/null 2>&1; then
  INIT=systemd
else
  INIT=none
fi

MARCH="$(uname -m)"
case "$MARCH" in
  x86_64|amd64)   MARCH=x86_64;  DEBARCH=amd64 ;;
  aarch64|arm64)  MARCH=aarch64; DEBARCH=arm64 ;;
  armv7l|armv7)   MARCH=armv7;   DEBARCH=armhf ;;
  mipsel|mipsle)  MARCH=mipsel;  DEBARCH=mipsel ;;
  mips)           DEBARCH=mips ;;
  riscv64)        DEBARCH=riscv64 ;;
  *)              DEBARCH="$MARCH" ;;
esac

in_container() {
  [ -f /.dockerenv ] && return 0
  command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -c >/dev/null 2>&1
}

# ---------------------------------------------------------------- 二进制定位
#
# 官方 debian/mimic.install 把 out/mimic 装进 usr/sbin；上游 OpenWrt 包装进
# usr/bin。写死任何一个都会在混装时出现「两个 mimic」，所以每次都查。

MIMIC_BIN=""
locate_mimic() {
  for p in /usr/sbin/mimic /usr/bin/mimic /usr/local/sbin/mimic /usr/local/bin/mimic; do
    if [ -x "$p" ]; then MIMIC_BIN="$p"; return 0; fi
  done
  MIMIC_BIN="$(command -v mimic 2>/dev/null || true)"
  [ -n "$MIMIC_BIN" ] && [ -x "$MIMIC_BIN" ]
}

# 本脚本自行安装二进制时的落点，与对应上游包保持一致
bindir() { if [ "$FAMILY" = deb ]; then echo /usr/sbin; else echo /usr/bin; fi; }

mimic_ver() {
  locate_mimic || { echo "未安装"; return 1; }
  v="$("$MIMIC_BIN" --version 2>/dev/null | head -1)"
  [ -n "$v" ] && echo "$v" || echo "未知版本"
}

kmod_loaded()    { [ -d /sys/module/mimic ]; }
kmod_available() { modinfo mimic >/dev/null 2>&1; }

# ---------------------------------------------------------------- 网卡

default_iface() {
  ip route show default 2>/dev/null |
    awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

IFACE=""
load_iface() {
  IFACE="$(cat "$CFGDIR/iface" 2>/dev/null || true)"
  [ -n "$IFACE" ] || IFACE="$(default_iface)"
  [ -n "$IFACE" ] || IFACE="$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')"
}

save_iface() { mkdir -p "$CFGDIR"; printf '%s\n' "$1" > "$CFGDIR/iface"; }

# ---------------------------------------------------------------- 选项存储

get_opt() { sed -n "s/^$1=//p" "$OPTFILE" 2>/dev/null | tail -1; }
set_opt() {
  mkdir -p "$CFGDIR"; : >> "$OPTFILE"
  sed -i "/^$1=/d" "$OPTFILE"
  [ -n "$2" ] && printf '%s=%s\n' "$1" "$2" >> "$OPTFILE"
  return 0
}

# ---------------------------------------------------------------- 连接参数策略
#
# mimic 允许在单条 filter 后面追加参数，覆盖全局默认值，例如：
#   filter = local=0.0.0.0:443,handshake=0:,keepalive=300:10:3:900
#
# 语义（docs/mimic.1.md「Handshake and Keepalive Parameters」）：
#
#   handshake = interval:retry
#     interval  两次 SYN 重试的间隔秒数，默认 2。
#               ★ 设为 0 会让该 filter 变成「被动」：mimic 不主动发起连接。
#     retry     放弃前的最大重试次数，默认 3。0 表示首次无响应即重置。
#
#   keepalive = time:interval:retry:stale
#     time      对端静默多久后发保活包，默认 180 秒；0 = 关闭保活。
#               ★ 官方建议：底层协议自带保活时（WireGuard 等隧道协议），
#                 此值应设得比协议自身的保活周期更高。
#     interval  未收到确认时的重试间隔，默认 10。
#     retry     最大重试次数，默认 3。
#     stale     底层链路静默多久后直接重置，默认 600 秒。
#               ★ 官方建议：用 remote= filter 且本地端口会变化时（服务重启、
#                 重连换端口）很有用，可回收被 mimic 捕获却已废弃的连接。
#
#   数字可以留空以沿用默认值，例如 handshake=:0 或 keepalive=60:::
#
# 下面两个函数返回追加到 filter 末尾的字符串（需含前导逗号），返回空串表示
# 全部沿用 mimic 默认值。

# 服务端 filter（local=）的参数
server_tuning() {
  get_opt server.tuning
}

# 客户端 filter（remote=）的参数
client_tuning() {
  get_opt client.tuning
}

# ---------------------------------------------------------------- 配置生成
#
# 服务端用通配地址 local=0.0.0.0:PORT / local=[::]:PORT：mimic 检测到通配
# filter 后会开 rtnetlink 套接字动态跟踪本机地址增删（src/run.c 的
# wildcard_count 分支），PPPoE 重拨或 DHCP 换址后过滤器依然有效。
# 注意 src/nl.c 里通配展开按地址族过滤，所以双栈必须写两条。
#
# 客户端直接把主机名交给 mimic：src/config.c 的 parse_filter 会 getaddrinfo，
# 并在 `mimic show` 里显示 "resolved from <host>"。

regen_conf() {
  load_iface
  [ -n "$IFACE" ] || { err "未能确定网卡，请先在主菜单安装或手动写入 $CFGDIR/iface"; return 1; }
  save_iface "$IFACE"

  conf="$CFGDIR/$IFACE.conf"
  tmp="$conf.new"
  nfilter=0
  lvl="$(get_opt log.verbosity)"; [ -n "$lvl" ] || lvl=info
  xm="$(get_opt xdp_mode)"

  {
    echo "# 由 faketcp v$FAKETCP_VER 生成，手动改动会在下次修改配置时被覆盖。"
    echo "# 配置语法：$UPSTREAM_GIT/blob/master/docs/mimic.1.md"
    echo
    echo "log.verbosity = $lvl"
    if [ -n "$xm" ]; then
      echo "xdp_mode = $xm"
    else
      echo "# xdp_mode 留空：mimic 优先 native，网卡不支持时自动回落 skb。"
      echo "# Intel igc/e1000/igb 或虚拟机 virtio_net 出现丢包时改为 skb。"
    fi
    echo

    if [ -s "$SRV_PORTS" ]; then
      st="$(server_tuning)"
      echo "# ── 服务端：通配本地地址，mimic 经 rtnetlink 自动跟踪 IP 变化 ──"
      while IFS= read -r port; do
        [ -n "$port" ] || continue
        echo "filter = local=0.0.0.0:$port$st"
        echo "filter = local=[::]:$port$st"
        nfilter=$((nfilter + 2))
      done < "$SRV_PORTS"
      echo
    fi

    if [ -s "$CLI_LIST" ]; then
      ct="$(client_tuning)"
      echo "# ── 客户端：主机名由 mimic 自行解析 ──"
      while IFS=' ' read -r host port _rest; do
        [ -n "$host" ] && [ -n "$port" ] || continue
        case "$host" in
          *:*) echo "filter = remote=[$host]:$port$ct" ;;
          *)   echo "filter = remote=$host:$port$ct" ;;
        esac
        nfilter=$((nfilter + 1))
      done < "$CLI_LIST"
    fi
  } > "$tmp" || { rm -f "$tmp"; err "写入 $tmp 失败"; return 1; }

  mv -f "$tmp" "$conf"
  if [ "$nfilter" -eq 0 ]; then
    warn "已生成 $conf，但其中没有任何 filter — mimic 会启动却不处理任何流量"
  else
    ok "已生成 $conf（$nfilter 条 filter）"
  fi
}

# ---------------------------------------------------------------- 服务单元

systemd_official_unit() {
  [ -f /lib/systemd/system/mimic@.service ] || [ -f /usr/lib/systemd/system/mimic@.service ]
}

svc_unit() {
  if systemd_official_unit; then echo "mimic@$IFACE"; else echo "faketcp@$IFACE"; fi
}

# 没有内核模块时，用关闭 TX 校验和卸载来兜底（docs/checksum-hacks.md）。
# 注意官方单元的 CapabilityBoundingSet 不含 CAP_SYS_MODULE，
# 所以这里绝不能放 modprobe——放了也必然失败。
ethtool_prestart='ExecStartPre=-/bin/sh -c "command -v ethtool >/dev/null 2>&1 && ethtool -K %i tx off || true"'

write_service() {
  load_iface
  locate_mimic || { warn "未找到 mimic 二进制，跳过服务单元生成"; return 1; }

  case "$INIT" in
    systemd)
      if systemd_official_unit; then
        # 复用官方 mimic@.service（Type=notify / Requires=modprobe@mimic.service /
        # RuntimeDirectory / ProtectSystem=strict），只在缺模块时补 ethtool 兜底。
        rm -f /etc/systemd/system/faketcp@.service
        if kmod_available; then
          rm -rf /etc/systemd/system/mimic@.service.d
        else
          mkdir -p /etc/systemd/system/mimic@.service.d
          {
            echo "[Service]"
            echo "$ethtool_prestart"
          } > /etc/systemd/system/mimic@.service.d/10-faketcp-ethtool.conf
        fi
      else
        rm -rf /etc/systemd/system/mimic@.service.d
        {
          echo "[Unit]"
          echo "Description = Mimic (faketcp) on %i"
          echo "After = network.target"
          echo "Wants = network.target"
          if kmod_available; then
            echo "Requires = modprobe@mimic.service"
            echo "After = modprobe@mimic.service"
          fi
          echo
          echo "[Service]"
          # mimic 自带 sd_notify（src/notify.c），无 NOTIFY_SOCKET 时安全跳过
          echo "Type = notify"
          kmod_available || echo "$ethtool_prestart"
          echo "ExecStart = $MIMIC_BIN run %i -F $CFGDIR/%i.conf"
          # 配置写错属于必死场景，用 on-failure 而非 always，避免无限重启刷日志
          echo "Restart = on-failure"
          echo "RestartSec = 3"
          echo
          echo "RuntimeDirectory = mimic"
          echo "RuntimeDirectoryMode = 0750"
          echo "RuntimeDirectoryPreserve = yes"
          echo
          echo "CapabilityBoundingSet = CAP_SYS_ADMIN CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW"
          echo "ProtectSystem = strict"
          echo
          echo "[Install]"
          echo "WantedBy = multi-user.target"
        } > /etc/systemd/system/faketcp@.service
      fi
      systemctl daemon-reload 2>/dev/null || true
      ;;

    openrc)
      cat > /etc/init.d/faketcp <<EOF
#!/sbin/openrc-run
description="Mimic UDP-over-fake-TCP obfuscator"

: \${iface:=\$(cat $CFGDIR/iface 2>/dev/null)}

supervisor="supervise-daemon"
command="$MIMIC_BIN"
command_args="run \${iface} -F $CFGDIR/\${iface}.conf"
supervise_daemon_args="--stdout /var/log/faketcp.log --stderr /var/log/faketcp.log"
respawn_delay=3
respawn_max=0
pidfile="/run/faketcp.pid"

depend() {
	need net
	after firewall
}

start_pre() {
	[ -n "\${iface}" ] || { eerror "未配置网卡：$CFGDIR/iface"; return 1; }
	[ -f "$CFGDIR/\${iface}.conf" ] || { eerror "缺少配置：$CFGDIR/\${iface}.conf"; return 1; }
	modprobe mimic 2>/dev/null
	[ -d /sys/module/mimic ] || ethtool -K "\${iface}" tx off 2>/dev/null
	return 0
}
EOF
      chmod +x /etc/init.d/faketcp
      ;;

    procd)
      cat > /etc/init.d/faketcp <<EOF
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1

start_service() {
	local iface conf
	iface="\$(cat $CFGDIR/iface 2>/dev/null)"
	[ -n "\$iface" ] || { echo "未配置网卡：$CFGDIR/iface" >&2; return 1; }
	conf="$CFGDIR/\$iface.conf"
	[ -f "\$conf" ] || { echo "缺少配置：\$conf" >&2; return 1; }

	modprobe mimic 2>/dev/null
	[ -d /sys/module/mimic ] || ethtool -K "\$iface" tx off 2>/dev/null

	procd_open_instance mimic
	procd_set_param command $MIMIC_BIN run "\$iface" -F "\$conf"
	procd_set_param respawn 3600 5 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
# 不注册 interface 触发器：filter 用的是通配地址，mimic 自己经 rtnetlink
# 跟踪 IP 变化，接口重载时重启服务只会造成无谓的连接中断。
EOF
      chmod +x /etc/init.d/faketcp
      ;;

    none)
      warn "未识别到服务管理器，只能手动运行： $MIMIC_BIN run $IFACE -F $CFGDIR/$IFACE.conf"
      return 1
      ;;
  esac
  return 0
}

svc() {
  load_iface
  case "$INIT" in
    systemd)
      u="$(svc_unit)"
      case "$1" in
        start)   systemctl enable "$u" 2>/dev/null; systemctl start "$u" ;;
        stop)    systemctl stop "$u" ;;
        restart) systemctl enable "$u" 2>/dev/null; systemctl restart "$u" ;;
        disable) systemctl disable --now "$u" 2>/dev/null || true ;;
        status)
          systemctl --no-pager status "$u" 2>/dev/null || true
          echo; sect "最近日志"
          journalctl -u "$u" -n 40 --no-pager 2>/dev/null || echo "（暂无日志）" ;;
      esac ;;
    openrc)
      case "$1" in
        start)   rc-update add faketcp default 2>/dev/null; rc-service faketcp start ;;
        stop)    rc-service faketcp stop ;;
        restart) rc-update add faketcp default 2>/dev/null; rc-service faketcp restart ;;
        disable) rc-update del faketcp default 2>/dev/null; rc-service faketcp stop 2>/dev/null || true ;;
        status)
          rc-service faketcp status || true
          echo; sect "日志 (/var/log/faketcp.log)"
          tail -n 40 /var/log/faketcp.log 2>/dev/null || echo "（暂无日志）" ;;
      esac ;;
    procd)
      case "$1" in
        start)   /etc/init.d/faketcp enable 2>/dev/null; /etc/init.d/faketcp start ;;
        stop)    /etc/init.d/faketcp stop ;;
        restart) /etc/init.d/faketcp enable 2>/dev/null; /etc/init.d/faketcp restart ;;
        disable) /etc/init.d/faketcp disable 2>/dev/null; /etc/init.d/faketcp stop 2>/dev/null || true ;;
        status)
          { /etc/init.d/faketcp status 2>/dev/null || pgrep -a mimic || echo "未运行"; }
          echo; sect "最近日志"
          logread 2>/dev/null | grep -i mimic | tail -n 25 || echo "（暂无日志）" ;;
      esac ;;
    none) warn "无服务管理器，无法执行 $1" ;;
  esac
}

svc_running() {
  case "$INIT" in
    systemd) systemctl is-active --quiet "$(svc_unit)" ;;
    openrc)  rc-service faketcp status >/dev/null 2>&1 ;;
    procd)   pgrep -f "mimic run" >/dev/null 2>&1 ;;
    *)       pgrep -f "mimic run" >/dev/null 2>&1 ;;
  esac
}

# ---------------------------------------------------------------- 部署自检
#
# `mimic run --check` 会完整走一遍：解析配置 → 抢锁 → 加载 BPF → 挂 TC/XDP →
# 灌 filter，然后退出（src/run.c:624）。因为要抢锁，服务运行时会冲突。

do_check() {
  load_iface
  locate_mimic || { err "mimic 未安装"; return 1; }
  conf="$CFGDIR/$IFACE.conf"
  [ -f "$conf" ] || { err "配置不存在：$conf"; return 1; }
  if svc_running; then
    warn "服务正在运行，自检需要独占锁；请先停止服务（菜单 6）再自检"
    return 1
  fi
  info "运行 $MIMIC_BIN run --check -F $conf $IFACE"
  echo
  if "$MIMIC_BIN" run --check -F "$conf" "$IFACE"; then
    echo; ok "自检通过：配置可解析，BPF 程序可加载并挂载到 $IFACE"
  else
    echo; err "自检失败，请对照上方日志排查"
    return 1
  fi
}

# ---------------------------------------------------------------- 安装

install_binary() {
  # $1 = URL；下载到临时文件后原子替换，避免覆盖到一半把系统弄坏
  d="$(bindir)"
  tmp="$d/.mimic.new.$$"
  if dlgh "$1" "$tmp"; then
    chmod +x "$tmp" && mv -f "$tmp" "$d/mimic" && locate_mimic && return 0
  fi
  rm -f "$tmp"
  return 1
}

fetch_src() {
  rm -rf "$1"; mkdir -p "$1"
  dlgh "$UPSTREAM_GIT/archive/refs/heads/master.tar.gz" /tmp/mimic-src.tgz || return 1
  tar -xzf /tmp/mimic-src.tgz -C "$1" --strip-components=1
  r=$?; rm -f /tmp/mimic-src.tgz; return $r
}

# ---- Debian / Ubuntu -------------------------------------------------

# 官方 release 只提供 bookworm/trixie/noble × amd64/arm64
install_deb_official_release() {
  [ -n "$CODENAME" ] || return 1
  case "$DEBARCH" in amd64|arm64) ;; *) return 1 ;; esac

  info "查询官方 release（$CODENAME/$DEBARCH）..."
  j=/tmp/mimic-rel.json
  dl "$UPSTREAM_API/releases/latest" "$j" 2>/dev/null || {
    rm -f "$j"; warn "api.github.com 不可达"; return 1; }
  urls="$(grep -o 'https://[^"]*\.deb' "$j" | sort -u)"
  rm -f "$j"

  cli="$(printf '%s\n' "$urls"  | grep -E "/${CODENAME}_mimic_[0-9][^/]*_${DEBARCH}\.deb$"      | head -1)"
  dkms="$(printf '%s\n' "$urls" | grep -E "/${CODENAME}_mimic-dkms_[0-9][^/]*_${DEBARCH}\.deb$" | head -1)"
  [ -n "$cli" ] && [ -n "$dkms" ] || { warn "官方 release 没有 $CODENAME/$DEBARCH 的包"; return 1; }

  td="$(mktemp -d)"
  info "下载官方 deb（mimic + mimic-dkms）..."
  dlgh "$cli" "$td/mimic.deb" && dlgh "$dkms" "$td/mimic-dkms.deb" || {
    rm -rf "$td"; warn "下载失败"; return 1; }

  apt-get install -y --no-install-recommends ethtool >/dev/null 2>&1 || true
  install_kernel_headers
  info "安装官方 deb ..."
  if apt-get install -y --no-install-recommends "$td/mimic.deb" "$td/mimic-dkms.deb"; then
    rm -rf "$td"; return 0
  fi
  rm -rf "$td"; warn "官方 deb 安装失败"; return 1
}

install_deb_from_repo() {
  apt-get update >/dev/null 2>&1 || true
  apt-cache show mimic >/dev/null 2>&1 || return 1
  info "发行版仓库里有 mimic，尝试安装 ..."
  install_kernel_headers
  apt-get install -y --no-install-recommends mimic mimic-dkms >/dev/null 2>&1 ||
    apt-get install -y --no-install-recommends mimic >/dev/null 2>&1 || return 1
  return 0
}

install_kernel_headers() {
  info "安装当前内核头（DKMS 需要）..."
  for p in "linux-headers-$(uname -r)" "proxmox-headers-$(uname -r)" \
           "pve-headers-$(uname -r)" proxmox-default-headers; do
    apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 && return 0
  done
  warn "未找到 $(uname -r) 的内核头 → 无内核模块，将用 ethtool 兜底"
  return 1
}

install_deb() {
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends ethtool >/dev/null 2>&1 || true

  if in_container; then
    # 容器内加载不了内核模块，直接用 kprobe 二进制 + ethtool 兜底
    info "检测到容器环境 → 使用 kprobe 二进制"
    apt-get install -y --no-install-recommends libbpf1 libxdp1 >/dev/null 2>&1 || true
    install_binary "$FALLBACK_REL/debian/mimic-debian-$MARCH" && return 0
    warn "预编译二进制不可用（$MARCH）"
    install_deb_build_local && return 0
    return 1
  fi

  install_deb_official_release && { post_install_kmod; return 0; }
  install_deb_from_repo        && { post_install_kmod; return 0; }
  warn "官方渠道不可用，回退自建预编译 ..."
  apt-get install -y --no-install-recommends libbpf1 libxdp1 >/dev/null 2>&1 || true
  install_binary "$FALLBACK_REL/debian/mimic-debian-$MARCH" && return 0
  warn "自建预编译不可用，回退本地编译 ..."
  install_deb_build_local
}

install_deb_build_local() {
  info "安装编译依赖 ..."
  apt-get install -y --no-install-recommends git make clang gcc pkg-config \
    libbpf-dev libelf-dev zlib1g-dev libxdp-dev bpftool dwarves libffi-dev \
    ca-certificates >/dev/null 2>&1 || { warn "编译依赖安装失败"; return 1; }
  fetch_src /usr/src/mimic || { warn "源码下载失败"; return 1; }
  # 无内核模块时用 kprobe；kprobe 必须配 STRIP_BTF_EXT=1（docs/checksum-hacks.md）
  if make -C /usr/src/mimic build-cli CHECKSUM_HACK=kprobe STRIP_BTF_EXT=1 >/dev/null 2>&1 &&
     [ -s /usr/src/mimic/out/mimic ]; then
    install -m755 /usr/src/mimic/out/mimic "$(bindir)/mimic"
    locate_mimic && ok "本地编译完成（kprobe + ethtool 兜底）" && return 0
  fi
  warn "本地编译失败"
  return 1
}

post_install_kmod() {
  echo mimic > /etc/modules-load.d/mimic.conf 2>/dev/null || true
  if ! modprobe mimic 2>/dev/null && command -v dkms >/dev/null 2>&1; then
    info "触发 DKMS 编译 ..."
    dkms autoinstall >/dev/null 2>&1 || true
    modprobe mimic 2>/dev/null || true
  fi
  if kmod_loaded; then
    ok "mimic 内核模块已加载（kfunc 校验和 hack，满速）"
  else
    warn "内核模块未加载 → 走 ethtool 兜底（关闭 TX 校验和卸载）"
  fi
}

# ---- Alpine ----------------------------------------------------------

install_alpine() {
  apk add --no-cache libbpf libxdp libffi ethtool >/dev/null 2>&1 || true
  avail="$(df -k / 2>/dev/null | awk 'NR==2{print int($4/1024)}')"
  if [ "${avail:-0}" -ge 2000 ]; then
    alpine_build_local && return 0
    warn "本地编译不可用，回退自建预编译 ..."
  else
    info "磁盘可用 ${avail:-?}MB（<2000），跳过本地编译"
  fi
  install_binary "$FALLBACK_REL/alpine/mimic-alpine-$MARCH" || {
    err "无 $MARCH 的 alpine 预编译产物"; return 1; }
  warn "预编译二进制无内核模块 → ethtool 兜底"
  return 0
}

alpine_build_local() {
  info "本地编译官方源码（二进制 + 内核模块）..."
  fl="$(uname -r | sed 's/.*-//')"
  apk add --no-cache git make clang gcc pahole bpftool linux-headers elfutils-dev \
    libbpf-dev libffi-dev argp-standalone libxdp-dev pkgconf musl-dev \
    "linux-${fl}-dev" >/dev/null 2>&1 || { warn "编译依赖安装失败"; return 1; }
  apk add --no-cache llvm >/dev/null 2>&1 ||
    apk add --no-cache "$(apk search -q '^llvm[0-9]*$' | sort -V | tail -n1)" >/dev/null 2>&1 || true
  for d in /usr/lib/llvm*/bin; do PATH="$d:$PATH"; done; export PATH

  fetch_src /usr/src/mimic || { warn "源码下载失败"; return 1; }

  # 首选 kfunc：二进制 + 内核模块，性能最好
  if BOOT_DIR=/boot make -C /usr/src/mimic KERNEL_UNAME="$(uname -r)" \
       VMLINUX_SUFFIX="-${fl}" >/dev/null 2>&1 && [ -s /usr/src/mimic/out/mimic.ko ]; then
    install -m755 /usr/src/mimic/out/mimic "$(bindir)/mimic"
    install -Dm644 /usr/src/mimic/out/mimic.ko "/lib/modules/$(uname -r)/extra/mimic.ko"
    depmod 2>/dev/null || true
    locate_mimic
    if modprobe mimic 2>/dev/null; then ok "kfunc 模块已加载（满速）"
    else warn "模块加载失败 → ethtool 兜底"; fi
    return 0
  fi

  warn "kfunc 编译失败，改用 kprobe 二进制"
  if make -C /usr/src/mimic build-cli CHECKSUM_HACK=kprobe STRIP_BTF_EXT=1 >/dev/null 2>&1 &&
     [ -s /usr/src/mimic/out/mimic ]; then
    install -m755 /usr/src/mimic/out/mimic "$(bindir)/mimic"
    locate_mimic && ok "已安装 kprobe 二进制（ethtool 兜底）" && return 0
  fi
  warn "kprobe 编译也失败"
  return 1
}

# ---- OpenWrt ---------------------------------------------------------

# 上游 net/mimic/Makefile 的依赖：+libbpf +libffi +kmod-sched-core +kmod-sched-bpf
# 少了 sched-bpf/sched-core，TC egress 分类器根本挂不上。
OWRT_DEPS="libbpf libffi kmod-sched-core kmod-sched-bpf ethtool"

# OpenWrt 的包架构（aarch64_generic / mipsel_24kc / arm_cortex-a7 ...）与
# uname -m 不是一回事，CI 产物按前者命名。
owrt_arch() {
  a="$(sed -n "s/^DISTRIB_ARCH='\(.*\)'\$/\1/p" /etc/openwrt_release 2>/dev/null | head -1)"
  [ -n "$a" ] || a="$MARCH"
  echo "$a"
}

# 新版 OpenWrt（SNAPSHOT）已换成 apk，24.10 仍是 opkg
owrt_pkg_install() {
  if command -v apk >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    apk add $1 >/dev/null 2>&1
  else
    # shellcheck disable=SC2086
    opkg install $1 >/dev/null 2>&1
  fi
}

owrt_pkg_update() {
  if command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1 || true
  else opkg update >/dev/null 2>&1 || true; fi
}

owrt_pkg_install_file() {
  if command -v apk >/dev/null 2>&1; then apk add --allow-untrusted "$1" >/dev/null 2>&1
  else opkg install "$1" >/dev/null 2>&1; fi
}

install_owrt() {
  oarch="$(owrt_arch)"
  owrt_pkg_update
  info "安装运行依赖：$OWRT_DEPS"
  owrt_pkg_install "$OWRT_DEPS" || warn "部分依赖安装失败；缺 kmod-sched-bpf 会导致 TC 挂载失败"

  # 1) 软件源里若已有 mimic，优先用它（可能自带 kmod-mimic）
  if owrt_pkg_install "mimic kmod-mimic" && locate_mimic; then
    ok "已从软件源安装 mimic"
    modprobe mimic 2>/dev/null || true
    return 0
  fi

  # 2) 自建预编译包（CI 用上游 OpenWrt SDK 交叉编译，参数与上游一致）
  info "软件源无 mimic，尝试自建预编译包（$oarch）..."
  if command -v apk >/dev/null 2>&1; then pext=apk; else pext=ipk; fi
  pkg="/tmp/mimic-openwrt.$pext"
  if dlgh "$FALLBACK_REL/openwrt/mimic-openwrt-$oarch.$pext" "$pkg" &&
     owrt_pkg_install_file "$pkg" && locate_mimic; then
    rm -f "$pkg"
    ok "已安装 mimic 包（$oarch）"
    warn "未附带内核模块 → ethtool 关闭 TX 卸载兜底"
    return 0
  fi
  rm -f "$pkg"

  # 3) 最后一级：裸二进制
  info "包安装未成功，回退裸二进制 ..."
  if install_binary "$FALLBACK_REL/openwrt/mimic-openwrt-$oarch"; then
    warn "裸二进制无内核模块 → ethtool 兜底"
    info "提示：Realtek / MediaTek 网卡驱动不使用 csum_offset，本就无需校验和 hack"
    return 0
  fi

  err "没有 $oarch 的 OpenWrt 预编译产物"
  info "可按上游文档自行构建：$UPSTREAM_GIT/tree/openwrt"
  return 1
}

# ---- 编排 ------------------------------------------------------------

cleanup_old_units() {
  load_iface
  if [ "$INIT" = systemd ]; then
    systemctl disable --now "faketcp@$IFACE" 2>/dev/null || true
    rm -f /etc/systemd/system/faketcp@.service
    rm -rf /etc/systemd/system/mimic@.service.d
    systemctl daemon-reload 2>/dev/null || true
  fi
  if [ -x /etc/init.d/faketcp ]; then
    rc-service faketcp stop 2>/dev/null || true
    rc-update del faketcp default 2>/dev/null || true
    /etc/init.d/faketcp stop 2>/dev/null || true
    /etc/init.d/faketcp disable 2>/dev/null || true
  fi
  rm -f /etc/init.d/faketcp
  # 不再通配删 /run/mimic/*.lock：锁文件名是 <netns>_<ifindex>.lock，
  # 通配会误杀同机其它网卡的实例；且 mimic 自己会检测陈旧锁并清理。
}

install_entry() {
  src="$0"
  case "$src" in ""|-|/dev/*|/proc/*) src="" ;; esac
  if [ -n "$src" ] && [ -f "$src" ]; then
    real="$(readlink -f "$src" 2>/dev/null || echo "$src")"
    [ "$real" = "$SELF" ] || cp -f "$real" "$SELF" || return 1
  else
    info "从管道运行，重新下载管理脚本作为入口 ..."
    dlgh "$RAW_SELF" "$SELF" || { warn "管理入口安装失败"; return 1; }
  fi
  chmod +x "$SELF"
  ln -sf mimic-manager /usr/bin/faketcp
  return 0
}

do_install() {
  cleanup_old_units
  case "$FAMILY" in
    deb)    install_deb ;;
    alpine) install_alpine ;;
    owrt)   install_owrt ;;
  esac || { err "安装失败"; return 1; }

  locate_mimic || { err "安装后仍未找到 mimic 二进制"; return 1; }
  load_iface
  [ -n "$IFACE" ] && save_iface "$IFACE"
  write_service
  install_entry
  ok "安装完成：$MIMIC_BIN（$(mimic_ver)）"
  ok "管理入口：faketcp / mimic-manager；默认网卡：$IFACE"
  kmod_loaded && ok "校验和 hack：kfunc（内核模块已加载）" ||
    warn "校验和 hack：无模块 → ethtool 关闭 TX 卸载兜底"
  [ -s "$SRV_PORTS" ] || [ -s "$CLI_LIST" ] ||
    info "下一步：菜单 2 配置服务端，或菜单 3 配置客户端"
}

do_update() {
  locate_mimic || { err "尚未安装"; return 1; }
  case "$FAMILY" in
    deb)
      info "当前：$(mimic_ver)"
      if install_deb_official_release; then post_install_kmod; ok "已更新"
      else warn "官方渠道无更新或不可达"; return 1; fi ;;
    *)
      case "$FAMILY" in
        alpine) u="$FALLBACK_REL/alpine/mimic-alpine-$MARCH" ;;
        owrt)   u="$FALLBACK_REL/openwrt/mimic-openwrt-$(owrt_arch)" ;;
      esac
      info "检查更新 ..."
      tmp="/tmp/mimic.candidate.$$"
      dlgh "$u" "$tmp" || { rm -f "$tmp"; warn "下载失败（可能没有对应架构的产物）"; return 1; }
      if cmp -s "$tmp" "$MIMIC_BIN"; then rm -f "$tmp"; ok "已是最新版"; return 0; fi
      chmod +x "$tmp"; mv -f "$tmp" "$MIMIC_BIN"
      ok "已更新到最新构建" ;;
  esac
  write_service
  svc_running && { info "重启服务以应用新版本 ..."; svc restart; }
  return 0
}

do_uninstall() {
  printf "%s将删除 mimic、%s 下全部配置与本脚本安装的服务，确认? [y/N] %s" "$RED" "$CFGDIR" "$R"
  read -r a
  case "$a" in y|Y|yes|YES) ;; *) echo "已取消"; return 0 ;; esac

  svc disable
  cleanup_old_units
  rmmod mimic 2>/dev/null || true
  rm -f /lib/modules/*/extra/mimic.ko 2>/dev/null || true
  depmod 2>/dev/null || true
  rm -f /etc/modules-load.d/mimic.conf

  case "$FAMILY" in
    deb)
      apt-get purge -y mimic mimic-dkms >/dev/null 2>&1 || true ;;
    owrt)
      if command -v apk >/dev/null 2>&1; then apk del mimic kmod-mimic >/dev/null 2>&1 || true
      else opkg remove mimic kmod-mimic >/dev/null 2>&1 || true; fi ;;
    alpine)
      rm -rf /usr/src/mimic ;;
  esac
  rm -f /usr/sbin/mimic /usr/bin/mimic
  rm -rf "$CFGDIR"
  rm -f /usr/bin/faketcp "$SELF"
  ok "已完全卸载（未改动防火墙及其他配置）"
}

# ---------------------------------------------------------------- 配置菜单

cfg_server() {
  mkdir -p "$CFGDIR"; : >> "$SRV_PORTS"
  while :; do
    cls
    load_iface
    sect "服务端端口（通配本地地址，IPv4 + IPv6）"
    printf "  网卡: %s%s%s\n" "$CYN" "$IFACE" "$R"
    printf "  %s生成的 filter 形如 local=0.0.0.0:PORT 与 local=[::]:PORT%s\n" "$GRY" "$R"
    printf "  %smimic 会经 rtnetlink 跟踪本机地址变化，换 IP 无需改配置%s\n\n" "$GRY" "$R"
    if [ -s "$SRV_PORTS" ]; then cat -n "$SRV_PORTS"; else echo "  （尚未配置端口）"; fi
    printf "\n  %s1%s) 添加端口   %s2%s) 删除端口   %s0%s) 返回\n" "$GRN" "$R" "$GRN" "$R" "$YLW" "$R"
    printf "%s选择: %s" "$B" "$R"; read -r c
    case "$c" in
      1) printf "UDP 端口 (1-65535): "; read -r port
         if echo "$port" | grep -qE '^[0-9]+$' && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
           if grep -qxF "$port" "$SRV_PORTS" 2>/dev/null; then warn "端口 $port 已存在"
           else printf '%s\n' "$port" >> "$SRV_PORTS"; regen_conf; fi
         else warn "端口须为 1-65535 的数字"; fi
         pause ;;
      2) if [ -s "$SRV_PORTS" ]; then
           printf "删除第几行: "; read -r n
           if echo "$n" | grep -qE '^[0-9]+$'; then sed -i "${n}d" "$SRV_PORTS"; regen_conf
           else warn "请输入行号"; fi
         else warn "列表为空"; fi
         pause ;;
      0) break ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

cfg_client() {
  mkdir -p "$CFGDIR"; : >> "$CLI_LIST"
  while :; do
    cls
    load_iface
    sect "客户端远端（服务端的 IP/域名 + 端口）"
    printf "  网卡: %s%s%s\n" "$CYN" "$IFACE" "$R"
    printf "  %s生成的 filter 形如 remote=HOST:PORT，域名由 mimic 自行解析%s\n\n" "$GRY" "$R"
    if [ -s "$CLI_LIST" ]; then cat -n "$CLI_LIST"; else echo "  （尚未配置远端）"; fi
    printf "\n  %s1%s) 添加远端   %s2%s) 删除远端   %s0%s) 返回\n" "$GRN" "$R" "$GRN" "$R" "$YLW" "$R"
    printf "%s选择: %s" "$B" "$R"; read -r c
    case "$c" in
      1) printf "远端 IP 或域名: "; read -r host
         printf "端口 (1-65535): "; read -r port
         if [ -z "$host" ]; then warn "主机不能为空"
         elif ! echo "$port" | grep -qE '^[0-9]+$' || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
           warn "端口须为 1-65535 的数字"
         elif grep -qxF "$host $port" "$CLI_LIST" 2>/dev/null; then warn "该远端已存在"
         else printf '%s %s\n' "$host" "$port" >> "$CLI_LIST"; regen_conf; fi
         pause ;;
      2) if [ -s "$CLI_LIST" ]; then
           printf "删除第几行: "; read -r n
           if echo "$n" | grep -qE '^[0-9]+$'; then sed -i "${n}d" "$CLI_LIST"; regen_conf
           else warn "请输入行号"; fi
         else warn "列表为空"; fi
         pause ;;
      0) break ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

cfg_advanced() {
  while :; do
    cls
    sect "高级选项"
    cur_x="$(get_opt xdp_mode)"; cur_l="$(get_opt log.verbosity)"
    cur_st="$(get_opt server.tuning)"; cur_ct="$(get_opt client.tuning)"
    printf "  XDP 模式       : %s%s%s\n" "$CYN" "${cur_x:-自动（native，不支持则 skb）}" "$R"
    printf "  日志级别       : %s%s%s\n" "$CYN" "${cur_l:-info}" "$R"
    printf "  服务端连接参数 : %s%s%s\n" "$CYN" "${cur_st:-mimic 默认}" "$R"
    printf "  客户端连接参数 : %s%s%s\n\n" "$CYN" "${cur_ct:-mimic 默认}" "$R"
    printf "  %s1%s) 切换 XDP 模式（自动 / skb / native）\n" "$GRN" "$R"
    printf "  %s2%s) 设置日志级别（error/warn/info/debug/trace）\n" "$GRN" "$R"
    printf "  %s3%s) 服务端 handshake/keepalive 参数\n" "$GRN" "$R"
    printf "  %s4%s) 客户端 handshake/keepalive 参数\n" "$GRN" "$R"
    printf "  %s0%s) 返回\n" "$YLW" "$R"
    printf "%s选择: %s" "$B" "$R"; read -r c
    case "$c" in
      1) printf "输入 auto / skb / native: "; read -r v
         case "$v" in
           auto|"") set_opt xdp_mode ""; regen_conf ;;
           skb|native) set_opt xdp_mode "$v"; regen_conf ;;
           *) warn "只接受 auto / skb / native" ;;
         esac; pause ;;
      2) printf "输入 error/warn/info/debug/trace: "; read -r v
         case "$v" in
           error|warn|info|debug|trace) set_opt log.verbosity "$v"; regen_conf ;;
           *) warn "无效级别" ;;
         esac; pause ;;
      3|4) [ "$c" = 3 ] && key=server.tuning || key=client.tuning
         printf "%s格式：,handshake=interval:retry,keepalive=time:interval:retry:stale%s\n" "$GRY" "$R"
         printf "%s示例：,handshake=0:  （被动，不主动发起连接）%s\n" "$GRY" "$R"
         printf "%s示例：,keepalive=300:10:3:900  （保活 300s，900s 无底层流量则重置）%s\n" "$GRY" "$R"
         printf "%s留空 = 全部使用 mimic 默认值%s\n" "$GRY" "$R"
         printf "输入: "; read -r v
         case "$v" in
           "") set_opt "$key" ""; regen_conf ;;
           ,*) set_opt "$key" "$v"; regen_conf ;;
           *)  warn "必须以逗号开头，例如 ,handshake=0:" ;;
         esac; pause ;;
      0) break ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

view_cfg() {
  load_iface
  locate_mimic || MIMIC_BIN="（未安装）"
  sect "环境"
  printf "  系统: %s%s%s\n" "$CYN" "${PRETTY:-$OSID}" "$R"
  printf "  架构: %s%s%s   服务管理: %s%s%s\n" "$CYN" "$MARCH" "$R" "$CYN" "$INIT" "$R"
  printf "  网卡: %s%s%s\n" "$CYN" "$IFACE" "$R"
  printf "  二进制: %s%s%s\n" "$CYN" "$MIMIC_BIN" "$R"
  printf "  版本: %s%s%s\n" "$CYN" "$(mimic_ver 2>/dev/null)" "$R"
  if kmod_loaded; then
    printf "  校验和 hack: %skfunc（内核模块已加载）%s\n" "$GRN" "$R"
  else
    printf "  校验和 hack: %s无模块 → ethtool 关闭 TX 卸载%s\n" "$YLW" "$R"
  fi
  if [ "$INIT" = systemd ]; then
    printf "  服务单元: %s%s%s\n" "$CYN" "$(svc_unit)" "$R"
  fi
  echo
  sect "服务端端口 ($SRV_PORTS)"
  [ -s "$SRV_PORTS" ] && cat -n "$SRV_PORTS" || echo "  （无）"
  echo
  sect "客户端远端 ($CLI_LIST)"
  [ -s "$CLI_LIST" ] && cat -n "$CLI_LIST" || echo "  （无）"
  echo
  sect "生成的配置 ($CFGDIR/$IFACE.conf)"
  [ -f "$CFGDIR/$IFACE.conf" ] && cat "$CFGDIR/$IFACE.conf" || echo "  （未生成）"
  echo
  printf "%s提示：mimic 给每个 UDP 包增加 12 字节。隧道协议请把 MTU 调低 12。%s\n" "$GRY" "$R"
  printf "%s      防火墙需同时放行 TCP 与 UDP（见官方 getting-started.md）。%s\n" "$GRY" "$R"
}

# ---------------------------------------------------------------- 主菜单

menu() {
  while :; do
    cls
    load_iface
    printf "%s%s═════ faketcp · mimic 管理器 v%s ═════%s\n" "$B" "$BLU" "$FAKETCP_VER" "$R"
    printf "%s%s / %s / %s   网卡 %s%s\n\n" "$GRY" "${PRETTY:-$OSID}" "$MARCH" "$INIT" "$IFACE" "$R"
    printf "   %s1%s) 安装 / 修复        %s2%s) 配置服务端\n"  "$GRN" "$R" "$GRN" "$R"
    printf "   %s3%s) 配置客户端         %s4%s) 高级选项\n"    "$GRN" "$R" "$GRN" "$R"
    printf "   %s5%s) 查看配置           %s6%s) 部署自检\n"    "$CYN" "$R" "$CYN" "$R"
    printf "   %s7%s) 启动               %s8%s) 停止\n"        "$GRN" "$R" "$YLW" "$R"
    printf "   %s9%s) 重启              %s10%s) 状态\n"        "$GRN" "$R" "$CYN" "$R"
    printf "  %s11%s) 更新              %s12%s) 完全卸载\n"    "$GRN" "$R" "$RED" "$R"
    printf "   %s0%s) 退出\n"                                  "$GRY" "$R"
    printf "%s请选择: %s" "$B" "$R"; read -r n
    case "$n" in
      1)  do_install; pause ;;
      2)  cfg_server ;;
      3)  cfg_client ;;
      4)  cfg_advanced ;;
      5)  view_cfg; pause ;;
      6)  do_check; pause ;;
      7)  svc start;   sleep 1; svc status; pause ;;
      8)  svc stop;    ok "已停止"; pause ;;
      9)  svc restart; sleep 1; svc status; pause ;;
      10) svc status; pause ;;
      11) do_update; pause ;;
      12) do_uninstall; pause ;;
      0)  exit 0 ;;
      *)  warn "无效选择"; pause ;;
    esac
  done
}

menu
