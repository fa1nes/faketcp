#!/bin/sh
set -u

REPO="https://github.com/hack3ric/mimic"
API="https://api.github.com/repos/hack3ric/mimic/releases/latest"
REL="https://github.com/fa1nes/faketcp/releases/download"
CFGDIR="/etc/mimic"
SELF="/usr/bin/mimic-manager"

E="$(printf '\033')"
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R="$E[0m"; B="$E[1m"; RED="$E[31m"; GRN="$E[32m"; YLW="$E[33m"
  BLU="$E[34m"; MAG="$E[35m"; CYN="$E[36m"; GRY="$E[90m"
else
  R= B= RED= GRN= YLW= BLU= MAG= CYN= GRY=
fi
ok()    { printf "%s✓ %s%s\n"  "$GRN" "$*" "$R"; }
info()  { printf "%s» %s%s\n"  "$CYN" "$*" "$R"; }
warn()  { printf "%s! %s%s\n"  "$YLW" "$*" "$R"; }
sect()  { printf "%s%s── %s ──%s\n" "$B" "$MAG" "$*" "$R"; }
cls()   { [ -t 1 ] && printf '%s[H%s[2J' "$E" "$E"; }
pause() { printf "\n%s按回车继续...%s" "$GRY" "$R"; read -r _k; }

die() { printf "%s✗ 错误: %s%s\n" "$RED" "$*" "$R" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "请用 root 运行"

if command -v curl >/dev/null 2>&1; then
  dl()  { curl -fsSL "$1"; }
  dlo() { curl -fsSL "$1" -o "$2"; }
  dlf() { curl -"$1" -fsSL "$2" 2>/dev/null; }
elif command -v wget >/dev/null 2>&1; then
  dl()  { wget -qO- "$1"; }
  dlo() { wget -qO "$2" "$1"; }
  dlf() { wget -qO- "$2" 2>/dev/null; }
else
  die "需要 curl 或 wget"
fi

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

ifip() {
  ip -"$1" -o addr show scope global dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

fmt() {
  case "$2" in *:*) echo "$1=[$2]:$3" ;; *) echo "$1=$2:$3" ;; esac
}
resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    *[!0-9.]*)
      if command -v getent >/dev/null 2>&1; then
        getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u
      elif command -v nslookup >/dev/null 2>&1; then
        nslookup "$1" 2>/dev/null | awk '/^Address[: ]/{print $NF}' | grep -v '#'
      else echo "$1"; fi ;;
    *) echo "$1" ;;
  esac
}

regen_conf() {
  IFACE="$(cat "$CFGDIR/iface" 2>/dev/null || echo "$IFACE")"
  conf="$CFGDIR/$IFACE.conf"
  {
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

write_service() {
  case "$INIT" in
    systemd)
      cat > /etc/systemd/system/faketcp@.service <<'EOF'
[Unit]
Description=Mimic faketcp on %i
After=network.target

[Service]
ExecStart=/usr/bin/mimic run -F /etc/mimic/%i.conf %i
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload 2>/dev/null ;;
    openrc)
      cat > /etc/init.d/faketcp <<'EOF'
#!/sbin/openrc-run
description="Mimic faketcp"
IFACE="$(cat /etc/mimic/iface 2>/dev/null)"
supervisor="supervise-daemon"
command="/usr/bin/mimic"
command_args="run -F /etc/mimic/${IFACE}.conf ${IFACE}"
supervise_daemon_args="--stdout /var/log/faketcp.log --stderr /var/log/faketcp.log"
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
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
      chmod +x /etc/init.d/faketcp ;;
  esac
}

svc() {
  case "$INIT" in
    systemd)
      case "$1" in
        start)   systemctl enable --now "faketcp@$IFACE" ;;
        stop)    systemctl stop "faketcp@$IFACE" ;;
        restart) systemctl restart "faketcp@$IFACE" ;;
        status)  systemctl --no-pager status "faketcp@$IFACE"; echo; sect "最近日志"; journalctl -u "faketcp@$IFACE" -n 30 --no-pager 2>/dev/null ;;
        disable) systemctl disable --now "faketcp@$IFACE" 2>/dev/null ;;
      esac ;;
    openrc)
      case "$1" in
        start)   rc-update add faketcp default 2>/dev/null; rc-service faketcp start ;;
        stop)    rc-service faketcp stop ;;
        restart) rc-service faketcp restart ;;
        status)  rc-service faketcp status; echo; sect "最近日志"; tail -n 30 /var/log/faketcp.log 2>/dev/null || echo "（暂无日志）" ;;
        disable) rc-update del faketcp default 2>/dev/null; rc-service faketcp stop 2>/dev/null ;;
      esac ;;
    procd)
      case "$1" in
        start)   /etc/init.d/faketcp enable; /etc/init.d/faketcp start ;;
        stop)    /etc/init.d/faketcp stop ;;
        restart) /etc/init.d/faketcp restart ;;
        status)  { /etc/init.d/faketcp status 2>/dev/null || pgrep -a mimic || echo "未运行"; }; echo; sect "最近日志"; logread 2>/dev/null | grep -i mimic | tail -n 30 || echo "（暂无日志）" ;;
        disable) /etc/init.d/faketcp disable 2>/dev/null; /etc/init.d/faketcp stop 2>/dev/null ;;
      esac ;;
  esac
}

latest_tag() {
  dl "$API" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4
}

install_entry() {
  [ "$(readlink -f "$0" 2>/dev/null || echo "$0")" = "$SELF" ] || { cp "$0" "$SELF"; chmod +x "$SELF"; }
  ln -sf mimic-manager /usr/bin/faketcp
}

install_deb() {
  am="$(uname -m)"
  info "下载预编译 mimic ($am) ..."
  dlo "$REL/debian/mimic-debian-$am" /usr/bin/mimic && [ -s /usr/bin/mimic ] \
    || die "下载预编译包失败，请先在 Actions 运行 build-debian-mimic 生成"
  chmod +x /usr/bin/mimic
  info "安装运行库 ..."
  apt-get install -y --no-install-recommends libbpf1 libxdp1 >/dev/null 2>&1 || true
}

install_alpine() {
  am="$(uname -m)"
  info "尝试下载预编译 mimic ($am) ..."
  if dlo "$REL/alpine/mimic-alpine-$am" /usr/bin/mimic && [ -s /usr/bin/mimic ]; then
    chmod +x /usr/bin/mimic
    apk add --no-cache libbpf libxdp libffi >/dev/null 2>&1 || true
    ok "已安装预编译 mimic（无需本地编译）"
    return
  fi
  rm -f /usr/bin/mimic
  warn "无预编译包，回退本地源码编译（约需 1.5GB 空间）"
  avail="$(df -k / 2>/dev/null | awk 'NR==2{print int($4/1024)}')"
  [ -n "$avail" ] && [ "$avail" -lt 1500 ] && \
    die "磁盘不足：当前 ${avail}MB，编译工具链约需 1500MB。请扩容，或用 GitHub Actions 生成预编译包"
  info "安装编译依赖 ..."
  apk add --no-cache git make clang gcc pahole bpftool linux-headers \
    elfutils-dev libbpf-dev libffi-dev argp-standalone libxdp-dev pkgconf musl-dev || die "依赖安装失败"
  info "克隆并编译源码 ..."
  rm -rf /usr/src/mimic
  git clone --depth 1 "$REPO" /usr/src/mimic || die "克隆失败"
  make -C /usr/src/mimic build-cli CHECKSUM_HACK=kprobe || die "编译失败"
  install -m755 /usr/src/mimic/out/mimic /usr/bin/mimic || die "未找到编译产物 out/mimic"
}

install_owrt() {
  am="$(uname -m)"
  info "下载预编译 mimic ($am) ..."
  dlo "$REL/openwrt/mimic-openwrt-$am" /usr/bin/mimic && [ -s /usr/bin/mimic ] \
    || die "下载预编译包失败，请先在 Actions 运行 build-openwrt-mimic 生成"
  chmod +x /usr/bin/mimic
  info "安装运行库 ..."
  opkg update >/dev/null 2>&1 || true
  opkg install libbpf libxdp libffi >/dev/null 2>&1 \
    || warn "运行库可能不全，若无法启动请手动 opkg install libbpf libxdp"
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

gen_server_filters() {
  : > "$CFGDIR/server.filters"
  [ -f "$CFGDIR/server.ports" ] || return
  while IFS= read -r port; do
    [ -n "$port" ] || continue
    [ -n "$1" ] && fmt local "$1" "$port" >> "$CFGDIR/server.filters"
    [ -n "$2" ] && fmt local "$2" "$port" >> "$CFGDIR/server.filters"
  done < "$CFGDIR/server.ports"
}

cfg_server() {
  echo "$IFACE" > "$CFGDIR/iface"
  touch "$CFGDIR/server.ports"
  p4="$(ifip 4)"; p6="$(ifip 6)"
  [ -s "$CFGDIR/server.ports" ] && { gen_server_filters "$p4" "$p6"; regen_conf; }
  while :; do
    cls
    sect "服务端端口管理（自动 IPv4/IPv6 双栈）"
    printf "  网卡 %s IPv4: %s%s%s  IPv6: %s%s%s\n\n" "$IFACE" "$GRN" "${p4:-无}" "$R" "$GRN" "${p6:-无}" "$R"
    printf "  %s1%s) 添加端口\n" "$GRN" "$R"
    printf "  %s2%s) 查看端口\n" "$GRN" "$R"
    printf "  %s3%s) 删除端口\n" "$GRN" "$R"
    printf "  %s0%s) 返回\n"     "$YLW" "$R"
    printf "%s选择: %s" "$B" "$R"; read -r c
    case "$c" in
      1) printf "UDP 端口: "; read -r port
         if echo "$port" | grep -qE '^[0-9]+$'; then
           grep -qxF "$port" "$CFGDIR/server.ports" || echo "$port" >> "$CFGDIR/server.ports"
           gen_server_filters "$p4" "$p6"; regen_conf; ok "已添加端口 $port（IPv4/IPv6 双栈）"
         else warn "端口须为数字"; fi ;;
      2) [ -s "$CFGDIR/server.ports" ] && cat -n "$CFGDIR/server.ports" || echo "（空）" ;;
      3) if [ -s "$CFGDIR/server.ports" ]; then
           cat -n "$CFGDIR/server.ports"
           printf "删除第几行: "; read -r n
           echo "$n" | grep -q '^[0-9]\+$' && { sed -i "${n}d" "$CFGDIR/server.ports"; gen_server_filters "$p4" "$p6"; regen_conf; }
         else echo "（空）"; fi ;;
      0) break ;;
    esac
    pause
  done
}

cfg_client() {
  echo "$IFACE" > "$CFGDIR/iface"
  touch "$CFGDIR/client.list"
  while :; do
    cls
    sect "客户端远端管理"
    printf "  %s1%s) 添加远端\n" "$GRN" "$R"
    printf "  %s2%s) 查看远端\n" "$GRN" "$R"
    printf "  %s3%s) 删除远端\n" "$GRN" "$R"
    printf "  %s0%s) 返回\n"     "$YLW" "$R"
    printf "%s选择: %s" "$B" "$R"; read -r c
    case "$c" in
      1) printf "远端 IP 或域名: "; read -r host
         printf "端口: "; read -r port
         [ -n "$host" ] && [ -n "$port" ] && { echo "$host $port" >> "$CFGDIR/client.list"; regen_conf; } ;;
      2) [ -s "$CFGDIR/client.list" ] && cat -n "$CFGDIR/client.list" || echo "（空）" ;;
      3) if [ -s "$CFGDIR/client.list" ]; then
           cat -n "$CFGDIR/client.list"
           printf "删除第几行: "; read -r n
           echo "$n" | grep -q '^[0-9]\+$' && { sed -i "${n}d" "$CFGDIR/client.list"; regen_conf; }
         else echo "（空）"; fi ;;
      0) break ;;
    esac
    pause
  done
}

view_cfg() {
  printf "系统: %s%s%s  架构: %s%s%s  网卡: %s%s%s  服务: %s%s%s\n" \
    "$CYN" "$ID" "$R" "$CYN" "$ARCH" "$R" "$CYN" "$IFACE" "$R" "$CYN" "$INIT" "$R"
  sect "服务端端口 ($CFGDIR/server.ports)"
  [ -s "$CFGDIR/server.ports" ] && cat -n "$CFGDIR/server.ports" || echo "（无）"
  sect "客户端远端 ($CFGDIR/client.list)"
  [ -s "$CFGDIR/client.list" ] && cat -n "$CFGDIR/client.list" || echo "（无）"
  sect "生成的配置 ($CFGDIR/$IFACE.conf)"
  [ -f "$CFGDIR/$IFACE.conf" ] && cat "$CFGDIR/$IFACE.conf" || echo "（未生成）"
}

do_update() {
  cur="$(cat "$CFGDIR/version" 2>/dev/null || echo 无)"
  new="$(latest_tag)"
  printf "当前版本: %s%s%s   最新版本: %s%s%s\n" "$YLW" "$cur" "$R" "$GRN" "${new:-未知}" "$R"
  [ -n "$new" ] || { warn "无法获取最新版本"; return; }
  [ "$cur" = "$new" ] && { ok "已是最新版本"; return; }
  printf "%s发现新版本 %s，是否更新? [y/N] %s" "$B" "$new" "$R"; read -r a
  case "$a" in y|Y) do_install ;; *) echo "已取消" ;; esac
}

do_uninstall() {
  printf "%s将删除 mimic 及 %s 下全部配置与服务，确认? [y/N] %s" "$RED" "$CFGDIR" "$R"; read -r a
  case "$a" in y|Y) ;; *) echo "已取消"; return ;; esac
  svc disable
  case "$PKG" in
    deb)    apt-get purge -y mimic mimic-dkms 2>/dev/null; rm -f /usr/bin/mimic ;;
    owrt)   opkg remove mimic kmod-mimic 2>/dev/null; rm -f /usr/bin/mimic ;;
    alpine) rm -f /usr/bin/mimic; rm -rf /usr/src/mimic ;;
  esac
  if [ "$INIT" = systemd ]; then
    rm -f /etc/systemd/system/faketcp@.service
    systemctl daemon-reload 2>/dev/null
  fi
  rm -f /etc/init.d/faketcp
  rm -rf "$CFGDIR"
  rm -f /usr/bin/faketcp "$SELF"
  ok "已完全卸载（未改动防火墙及其他配置）"
}

menu() {
  while :; do
    cls
    printf "%s%s===== mimic-manager =====%s\n" "$B" "$BLU" "$R"
    printf "%s系统: %s/%s  服务: %s%s\n\n" "$GRY" "$ID" "$ARCH" "$INIT" "$R"
    printf "  %s1%s) 安装\n"       "$GRN" "$R"
    printf "  %s2%s) 配置服务端\n" "$GRN" "$R"
    printf "  %s3%s) 配置客户端\n" "$GRN" "$R"
    printf "  %s4%s) 查看配置\n"   "$CYN" "$R"
    printf "  %s5%s) 启动\n"       "$GRN" "$R"
    printf "  %s6%s) 停止\n"       "$YLW" "$R"
    printf "  %s7%s) 重启\n"       "$YLW" "$R"
    printf "  %s8%s) 状态\n"       "$CYN" "$R"
    printf "  %s9%s) 更新\n"       "$MAG" "$R"
    printf " %s10%s) 完全卸载\n"   "$RED" "$R"
    printf "  %s0%s) 退出\n"       "$GRY" "$R"
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
    pause
  done
}

menu
