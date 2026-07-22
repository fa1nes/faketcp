#!/bin/sh
# mimic-manager —— hack3ric/mimic (faketcp) 安装与配置管理脚本
# 仅用于管理自己的 Linux 设备。上游文档: https://github.com/hack3ric/mimic
set -u

REPO="https://github.com/hack3ric/mimic"
API="https://api.github.com/repos/hack3ric/mimic/releases/latest"
CFGDIR="/etc/mimic"
SELF="/usr/bin/mimic-manager"

# ---------- 颜色 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  E="$(printf '\033')"
  R="$E[0m"; B="$E[1m"; RED="$E[31m"; GRN="$E[32m"; YLW="$E[33m"
  BLU="$E[34m"; MAG="$E[35m"; CYN="$E[36m"; GRY="$E[90m"
else
  R= B= RED= GRN= YLW= BLU= MAG= CYN= GRY=
fi
ok()   { printf "%s✓ %s%s\n"  "$GRN" "$*" "$R"; }
info() { printf "%s» %s%s\n"  "$CYN" "$*" "$R"; }
warn() { printf "%s! %s%s\n"  "$YLW" "$*" "$R"; }
sect() { printf "%s%s── %s ──%s\n" "$B" "$MAG" "$*" "$R"; }

# ---------- 基础工具 ----------
die() { printf "%s✗ 错误: %s%s\n" "$RED" "$*" "$R" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "请用 root 运行"

if command -v curl >/dev/null 2>&1; then
  dl()  { curl -fsSL "$1"; }
  dlo() { curl -fsSL "$1" -o "$2"; }
  dlf() { curl -"$1" -fsSL "$2" 2>/dev/null; }   # 指定 4/6
elif command -v wget >/dev/null 2>&1; then
  dl()  { wget -qO- "$1"; }
  dlo() { wget -qO "$2" "$1"; }
  dlf() { wget -qO- "$2" 2>/dev/null; }
else
  die "需要 curl 或 wget"
fi

# ---------- 系统识别 ----------
. /etc/os-release 2>/dev/null || die "无法读取 /etc/os-release"
case "$ID" in
  debian|ubuntu)        PKG=deb;    INIT=systemd ;;
  alpine)               PKG=alpine; INIT=openrc ;;
  openwrt|immortalwrt)  PKG=owrt;   INIT=procd ;;
  *) die "不支持的系统: $ID" ;;
esac

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *)       ARCH="$(uname -m)" ;;
esac

default_iface() {
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'
}
IFACE="$(cat "$CFGDIR/iface" 2>/dev/null || default_iface)"
[ -n "$IFACE" ] || IFACE="$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2;exit}')"

mkdir -p "$CFGDIR"

# ---------- 公网 IP ----------
pubip() { # $1 = 4 或 6
  for u in "https://ipv$1.icanhazip.com" "https://api$([ "$1" = 6 ] && echo 64).ipify.org"; do
    v="$(dlf "$1" "$u")"; [ -n "$v" ] && { echo "$v" | tr -d '\r\n'; return; }
  done
  ip -"$1" -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

# ---------- 过滤器辅助 ----------
fmt() { # $1=local/remote $2=ip $3=port
  case "$2" in *:*) echo "$1=[$2]:$3" ;; *) echo "$1=$2:$3" ;; esac
}
resolve() { # 主机名/IP -> 一个或多个 IP
  case "$1" in
    *:*) echo "$1" ;;                                   # IPv6 字面量
    *[!0-9.]*)                                          # 主机名
      if command -v getent >/dev/null 2>&1; then
        getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u
      elif command -v nslookup >/dev/null 2>&1; then
        nslookup "$1" 2>/dev/null | awk '/^Address[: ]/{print $NF}' | grep -v '#'
      else echo "$1"; fi ;;
    *) echo "$1" ;;                                     # IPv4
  esac
}

regen_conf() {
  IFACE="$(cat "$CFGDIR/iface" 2>/dev/null || echo "$IFACE")"
  conf="$CFGDIR/$IFACE.conf"
  {
    echo "# 由 mimic-manager 生成，请勿手动编辑过滤器"
    if [ -f "$CFGDIR/server.filters" ]; then
      while IFS= read -r f; do [ -n "$f" ] && echo "filter = $f"; done < "$CFGDIR/server.filters"
    fi
    if [ -f "$CFGDIR/client.list" ]; then
      while IFS=' ' read -r host port; do
        [ -n "$host" ] || continue
        for ip in $(resolve "$host"); do echo "filter = $(fmt remote "$ip" "$port")"; done
      done < "$CFGDIR/client.list"
    fi
  } > "$conf"
  ok "已生成 $conf"
}

# ---------- 服务管理 ----------
write_service() {
  case "$INIT" in
    systemd)
      # 覆盖上游 mimic@.service：崩溃自动重启（开机自启由 enable 保证）
      mkdir -p /etc/systemd/system/mimic@.service.d
      cat > /etc/systemd/system/mimic@.service.d/restart.conf <<'EOF'
[Service]
Restart=always
RestartSec=3
EOF
      systemctl daemon-reload 2>/dev/null ;;
    openrc)
      # supervise-daemon 常驻监管，退出即拉起
      cat > /etc/init.d/faketcp <<'EOF'
#!/sbin/openrc-run
description="Mimic faketcp 混淆"
IFACE="$(cat /etc/mimic/iface 2>/dev/null)"
supervisor="supervise-daemon"
command="/usr/bin/mimic"
command_args="run -F /etc/mimic/${IFACE}.conf ${IFACE}"
respawn_delay=3
pidfile="/run/faketcp.pid"
start_pre() { modprobe mimic 2>/dev/null; return 0; }
EOF
      chmod +x /etc/init.d/faketcp ;;
    procd)
      cat > /etc/init.d/faketcp <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
  local iface; iface="$(cat /etc/mimic/iface 2>/dev/null)"
  procd_open_instance
  procd_set_param command /usr/bin/mimic run -F "/etc/mimic/${iface}.conf" "${iface}"
  procd_set_param respawn
  procd_close_instance
}
EOF
      chmod +x /etc/init.d/faketcp ;;
  esac
}

svc() { # start|stop|restart|status|disable
  case "$INIT" in
    systemd)
      case "$1" in
        start)   systemctl enable --now "mimic@$IFACE" ;;
        stop)    systemctl stop "mimic@$IFACE" ;;
        restart) systemctl restart "mimic@$IFACE" ;;
        status)  systemctl status "mimic@$IFACE" ;;
        disable) systemctl disable --now "mimic@$IFACE" 2>/dev/null ;;
      esac ;;
    openrc)
      case "$1" in
        start)   rc-update add faketcp default 2>/dev/null; rc-service faketcp start ;;
        stop)    rc-service faketcp stop ;;
        restart) rc-service faketcp restart ;;
        status)  rc-service faketcp status ;;
        disable) rc-update del faketcp default 2>/dev/null; rc-service faketcp stop 2>/dev/null ;;
      esac ;;
    procd)
      case "$1" in
        start)   /etc/init.d/faketcp enable; /etc/init.d/faketcp start ;;
        stop)    /etc/init.d/faketcp stop ;;
        restart) /etc/init.d/faketcp restart ;;
        status)  /etc/init.d/faketcp status 2>/dev/null || pgrep -a mimic || echo "未运行" ;;
        disable) /etc/init.d/faketcp disable 2>/dev/null; /etc/init.d/faketcp stop 2>/dev/null ;;
      esac ;;
  esac
}

# ---------- 版本 ----------
latest_tag() {
  dl "$API" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4
}

# ---------- 安装 ----------
install_entry() {
  [ "$(readlink -f "$0" 2>/dev/null || echo "$0")" = "$SELF" ] || { cp "$0" "$SELF"; chmod +x "$SELF"; }
  ln -sf mimic-manager /usr/bin/faketcp
}

install_deb() {
  cn="$VERSION_CODENAME"
  info "获取官方 Release ..."
  json="$(dl "$API")" || die "获取 Release 失败"
  urls="$(printf '%s\n' "$json" | grep -o 'https://[^"]*\.deb')"
  cli="$(printf  '%s\n' "$urls" | grep -E "/${cn}_mimic_[0-9][^\"]*_${ARCH}\.deb$"       | head -1)"
  dkms="$(printf '%s\n' "$urls" | grep -E "/${cn}_mimic-dkms_[0-9][^\"]*_${ARCH}\.deb$" | head -1)"
  [ -n "$cli" ] && [ -n "$dkms" ] || die "未找到匹配 $cn/$ARCH 的官方 deb 包"
  td="$(mktemp -d)"
  info "下载 $(basename "$cli") 与 dkms 包 ..."
  dlo "$cli" "$td/mimic.deb" && dlo "$dkms" "$td/mimic-dkms.deb" || { rm -rf "$td"; die "下载失败"; }
  apt-get update -y
  apt-get install -y "$td/mimic.deb" "$td/mimic-dkms.deb" || { rm -rf "$td"; die "安装失败"; }
  rm -rf "$td"
}

install_alpine() {
  info "安装编译依赖 ..."
  # 依赖对齐上游 building.md：clang 自带所需 llvm 运行库，无需独立的巨型 llvm 工具包
  apk add --no-cache git make clang gcc pahole bpftool linux-headers \
    elfutils-dev libbpf-dev libffi-dev argp-standalone libxdp-dev pkgconf musl-dev || die "依赖安装失败"
  info "克隆并编译源码 ..."
  rm -rf /usr/src/mimic
  git clone --depth 1 "$REPO" /usr/src/mimic || die "克隆失败"
  make -C /usr/src/mimic || die "编译失败"
  install -m755 /usr/src/mimic/out/mimic /usr/bin/mimic || die "未找到编译产物 out/mimic"
  if [ -f /usr/src/mimic/out/mimic.ko ]; then
    install -Dm644 /usr/src/mimic/out/mimic.ko "/lib/modules/$(uname -r)/extra/mimic.ko"
    depmod 2>/dev/null
  fi
}

install_owrt() {
  info "更新软件源 ..."
  opkg update || die "opkg update 失败"
  # 仅安装与当前内核匹配的包，不使用任何 --force，内核不匹配时 opkg 会自行拒绝
  opkg install kmod-mimic mimic || die "opkg 安装失败（可能内核不匹配或缺少软件源）"
}

do_install() {
  case "$PKG" in
    deb)    install_deb ;;
    alpine) install_alpine ;;
    owrt)   install_owrt ;;
  esac
  [ -n "$IFACE" ] && echo "$IFACE" > "$CFGDIR/iface"
  write_service
  install_entry
  latest_tag > "$CFGDIR/version" 2>/dev/null
  ok "安装完成。管理入口: faketcp / mimic-manager，默认网卡: $IFACE"
}

# ---------- 配置 ----------
cfg_server() {
  echo "$IFACE" > "$CFGDIR/iface"
  info "正在获取公网 IP ..."
  p4="$(pubip 4)"; p6="$(pubip 6)"
  printf "  IPv4: %s%s%s   IPv6: %s%s%s\n" "$GRN" "${p4:-无}" "$R" "$GRN" "${p6:-无}" "$R"
  printf "%s请输入 UDP 端口: %s" "$B" "$R"; read -r port
  [ -n "$port" ] || { warn "端口不能为空"; return; }
  : > "$CFGDIR/server.filters"
  [ -n "$p4" ] && fmt local "$p4" "$port" >> "$CFGDIR/server.filters"
  [ -n "$p6" ] && fmt local "$p6" "$port" >> "$CFGDIR/server.filters"
  regen_conf
  ok "服务端配置完成（网卡 $IFACE，端口 $port）"
}

cfg_client() {
  echo "$IFACE" > "$CFGDIR/iface"
  touch "$CFGDIR/client.list"
  while :; do
    sect "客户端远端管理"
    printf "  %s1%s) 添加   %s2%s) 查看   %s3%s) 删除   %s0%s) 返回\n" \
      "$GRN" "$R" "$GRN" "$R" "$GRN" "$R" "$YLW" "$R"
    printf "%s选择: %s" "$B" "$R"; read -r c
    case "$c" in
      1) printf "远端 IP 或域名: "; read -r host
         printf "端口: "; read -r port
         [ -n "$host" ] && [ -n "$port" ] && { echo "$host $port" >> "$CFGDIR/client.list"; regen_conf; } ;;
      2) [ -s "$CFGDIR/client.list" ] && cat -n "$CFGDIR/client.list" || echo "（空）" ;;
      3) [ -s "$CFGDIR/client.list" ] || { echo "（空）"; continue; }
         cat -n "$CFGDIR/client.list"
         printf "删除第几行: "; read -r n
         echo "$n" | grep -q '^[0-9]\+$' && { sed -i "${n}d" "$CFGDIR/client.list"; regen_conf; } ;;
      0) break ;;
    esac
  done
}

view_cfg() {
  printf "系统: %s%s%s  架构: %s%s%s  网卡: %s%s%s  服务: %s%s%s\n" \
    "$CYN" "$ID" "$R" "$CYN" "$ARCH" "$R" "$CYN" "$IFACE" "$R" "$CYN" "$INIT" "$R"
  sect "服务端过滤器 ($CFGDIR/server.filters)"
  [ -s "$CFGDIR/server.filters" ] && cat "$CFGDIR/server.filters" || echo "（无）"
  sect "客户端远端 ($CFGDIR/client.list)"
  [ -s "$CFGDIR/client.list" ] && cat -n "$CFGDIR/client.list" || echo "（无）"
  sect "生成的配置 ($CFGDIR/$IFACE.conf)"
  [ -f "$CFGDIR/$IFACE.conf" ] && cat "$CFGDIR/$IFACE.conf" || echo "（未生成）"
}

# ---------- 更新 ----------
do_update() {
  cur="$(cat "$CFGDIR/version" 2>/dev/null || echo 无)"
  new="$(latest_tag)"
  printf "当前版本: %s%s%s   最新版本: %s%s%s\n" "$YLW" "$cur" "$R" "$GRN" "${new:-未知}" "$R"
  [ -n "$new" ] || { warn "无法获取最新版本"; return; }
  [ "$cur" = "$new" ] && { ok "已是最新版本"; return; }
  printf "%s发现新版本 %s，是否更新? [y/N] %s" "$B" "$new" "$R"; read -r a
  case "$a" in y|Y) do_install ;; *) echo "已取消" ;; esac
}

# ---------- 卸载 ----------
do_uninstall() {
  printf "%s将删除 mimic 及 %s 下全部配置与服务，确认? [y/N] %s" "$RED" "$CFGDIR" "$R"; read -r a
  case "$a" in y|Y) ;; *) echo "已取消"; return ;; esac
  svc disable
  case "$PKG" in
    deb)    apt-get purge -y mimic mimic-dkms 2>/dev/null ;;
    owrt)   opkg remove mimic kmod-mimic 2>/dev/null ;;
    alpine) rm -f /usr/bin/mimic; rm -rf /usr/src/mimic
            rm -f "/lib/modules/$(uname -r)/extra/mimic.ko" 2>/dev/null; depmod 2>/dev/null ;;
  esac
  rm -f /etc/init.d/faketcp /etc/modules-load.d/mimic.conf
  rm -rf "$CFGDIR"
  rm -f /usr/bin/faketcp "$SELF"
  ok "已完全卸载（未改动防火墙及其他配置）"
}

# ---------- 菜单 ----------
menu() {
  while :; do
    echo
    printf "%s%s========= mimic-manager (%s/%s, %s) =========%s\n" \
      "$B" "$BLU" "$ID" "$ARCH" "$INIT" "$R"
    printf "  %s1%s) 安装         %s2%s) 配置服务端   %s3%s) 配置客户端\n" "$GRN" "$R" "$GRN" "$R" "$GRN" "$R"
    printf "  %s4%s) 查看配置     %s5%s) 启动         %s6%s) 停止\n"     "$CYN" "$R" "$GRN" "$R" "$YLW" "$R"
    printf "  %s7%s) 重启         %s8%s) 状态         %s9%s) 更新\n"     "$YLW" "$R" "$CYN" "$R" "$MAG" "$R"
    printf " %s10%s) 完全卸载     %s0%s) 退出\n"                          "$RED" "$R" "$GRY" "$R"
    printf "%s请选择: %s" "$B" "$R"; read -r n
    case "$n" in
      1) do_install ;;
      2) cfg_server ;;
      3) cfg_client ;;
      4) view_cfg ;;
      5) svc start ;;
      6) svc stop ;;
      7) svc restart ;;
      8) svc status ;;
      9) do_update ;;
      10) do_uninstall ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

menu
