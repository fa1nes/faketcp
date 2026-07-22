#!/bin/sh
set -u

REPO="https://github.com/hack3ric/mimic"
REL="https://github.com/fa1nes/faketcp/releases/download"
GHPROXY="${GHPROXY-https://ghfast.top}"
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
  dlo() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  dlo() { wget -qO "$2" "$1"; }
else
  die "需要 curl 或 wget"
fi

dlgh() {
  [ -n "$GHPROXY" ] && dlo "$GHPROXY/$1" "$2" && [ -s "$2" ] && return 0
  dlo "$1" "$2"
}

install_bin() {
  tmp="/usr/bin/.mimic.new"
  dlgh "$1" "$tmp" && [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
  chmod +x "$tmp"
  mv -f "$tmp" /usr/bin/mimic
}

fetch_src() {
  rm -rf "$1"; mkdir -p "$1"
  dlgh "$REPO/archive/refs/heads/master.tar.gz" /tmp/mimic-src.tgz \
    && tar -xzf /tmp/mimic-src.tgz -C "$1" --strip-components=1
  r=$?; rm -f /tmp/mimic-src.tgz; return $r
}

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
    echo "xdp_mode = skb"
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
      rm -f /etc/systemd/system/faketcp@.service
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
start_pre() { ethtool -K "${IFACE}" tx off gro off lro off 2>/dev/null; modprobe sch_ingress 2>/dev/null; rm -f /run/mimic/*.lock 2>/dev/null; : > /var/log/faketcp.log; return 0; }
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
  ethtool -K "$iface" tx off gro off lro off 2>/dev/null
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
        restart) modprobe mimic 2>/dev/null; systemctl enable "mimic@$IFACE" 2>/dev/null; systemctl restart "mimic@$IFACE" ;;
        status)  systemctl --no-pager status "mimic@$IFACE" 2>/dev/null
                 echo; sect "最近日志"; journalctl -u "mimic@$IFACE" -n 50 --no-pager 2>/dev/null ;;
        disable) systemctl disable --now "mimic@$IFACE" 2>/dev/null ;;
      esac ;;
    openrc)
      case "$1" in
        restart) rc-update add faketcp default 2>/dev/null; rc-service faketcp restart ;;
        status)  rc-service faketcp status; echo; sect "本次日志"; tail -n 20 /var/log/faketcp.log 2>/dev/null || echo "（暂无日志）" ;;
        disable) rc-update del faketcp default 2>/dev/null; rc-service faketcp stop 2>/dev/null ;;
      esac ;;
    procd)
      case "$1" in
        restart) /etc/init.d/faketcp enable; /etc/init.d/faketcp restart ;;
        status)  { /etc/init.d/faketcp status 2>/dev/null || pgrep -a mimic || echo "未运行"; }; echo; sect "本次日志"; logread 2>/dev/null | grep -i mimic | tail -n 15 || echo "（暂无日志）" ;;
        disable) /etc/init.d/faketcp disable 2>/dev/null; /etc/init.d/faketcp stop 2>/dev/null ;;
      esac ;;
  esac
}

bin_url() {
  case "$PKG" in
    deb)    echo "$REL/debian/mimic-debian-$(uname -m)" ;;
    alpine) echo "$REL/alpine/mimic-alpine-$(uname -m)" ;;
    owrt)   echo "$REL/openwrt/mimic-openwrt-$(uname -m)" ;;
  esac
}

install_entry() {
  [ "$(readlink -f "$0" 2>/dev/null || echo "$0")" = "$SELF" ] || { cp "$0" "$SELF"; chmod +x "$SELF"; }
  ln -sf mimic-manager /usr/bin/faketcp
}

install_deb() {
  cn="$VERSION_CODENAME"
  info "获取官方 Release ..."
  j=/tmp/mimic-rel.json
  dlo "https://api.github.com/repos/hack3ric/mimic/releases/latest" "$j" 2>/dev/null \
    || die "获取 Release 失败（api.github.com 不通）"
  u="$(grep -o 'https://[^"]*\.deb' "$j")"; rm -f "$j"
  cli="$(printf  '%s\n' "$u" | grep -E "/${cn}_mimic_[0-9][^\"]*_${ARCH}\.deb$"       | head -1)"
  dkms="$(printf '%s\n' "$u" | grep -E "/${cn}_mimic-dkms_[0-9][^\"]*_${ARCH}\.deb$" | head -1)"
  [ -n "$cli" ] && [ -n "$dkms" ] || die "未找到匹配 $cn/$ARCH 的官方 deb（仅 bookworm/trixie/noble amd64/arm64）"
  td="$(mktemp -d)"
  info "下载官方 deb（mimic + mimic-dkms，kfunc 满速）..."
  dlgh "$cli" "$td/a.deb" && dlgh "$dkms" "$td/b.deb" || { rm -rf "$td"; die "下载失败"; }
  info "安装当前内核头（DKMS 只为运行内核编译）..."
  apt-get install -y --no-install-recommends "linux-headers-$(uname -r)" >/dev/null 2>&1 \
    || apt-get install -y --no-install-recommends "pve-headers-$(uname -r)" >/dev/null 2>&1 \
    || apt-get install -y --no-install-recommends "proxmox-headers-$(uname -r)" >/dev/null 2>&1 \
    || warn "未找到当前内核头（$(uname -r)），DKMS 可能失败"
  info "安装官方 deb（--no-install-recommends 避免拉入无关内核）..."
  apt-get install -y --no-install-recommends "$td/a.deb" "$td/b.deb" \
    || { rm -rf "$td"; die "安装失败，见上方 DKMS 日志"; }
  rm -rf "$td"
  echo mimic > /etc/modules-load.d/mimic.conf
  modprobe mimic 2>/dev/null && ok "mimic 内核模块已加载（kfunc 满速）" || warn "模块未加载，检查 DKMS 日志"
}

install_alpine() {
  info "尝试下载预编译 mimic ..."
  if install_bin "$(bin_url)"; then
    apk add --no-cache libbpf libxdp libffi ethtool >/dev/null 2>&1 || true
    ok "已安装预编译 mimic（无需本地编译）"
    return
  fi
  warn "无预编译包，回退本地源码编译（约需 1.5GB 空间）"
  avail="$(df -k / 2>/dev/null | awk 'NR==2{print int($4/1024)}')"
  [ -n "$avail" ] && [ "$avail" -lt 1500 ] && \
    die "磁盘不足：当前 ${avail}MB，编译工具链约需 1500MB。请扩容，或用 GitHub Actions 生成预编译包"
  info "安装编译依赖 ..."
  apk add --no-cache git make clang gcc pahole bpftool linux-headers \
    elfutils-dev libbpf-dev libffi-dev argp-standalone libxdp-dev pkgconf musl-dev || die "依赖安装失败"
  info "下载并编译源码 ..."
  fetch_src /usr/src/mimic || die "源码下载失败"
  sed -i "s/if (padding_len > 0)/if (0)/" /usr/src/mimic/bpf/egress.c 2>/dev/null
  make -C /usr/src/mimic build-cli CHECKSUM_HACK=kprobe || die "编译失败"
  [ -s /usr/src/mimic/out/mimic ] || die "未找到编译产物 out/mimic"
  rm -f /usr/bin/mimic; install -m755 /usr/src/mimic/out/mimic /usr/bin/mimic
}

install_owrt() {
  info "下载预编译 mimic ..."
  install_bin "$(bin_url)" || die "下载预编译包失败，请先在 Actions 运行 build-openwrt-mimic 生成"
  info "安装运行库 ..."
  opkg update >/dev/null 2>&1 || true
  opkg install libbpf libxdp libffi ethtool >/dev/null 2>&1 \
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
  ok "安装完成。管理入口: faketcp / mimic-manager，默认网卡: $IFACE"
}

auto_update() {
  [ "$PKG" = deb ] && return
  [ -x /usr/bin/mimic ] || return
  write_service
  u="$(bin_url)"; [ -n "$u" ] || return
  info "检查更新 ..."
  tmp="/usr/bin/.mimic.new"
  dlgh "$u" "$tmp" && [ -s "$tmp" ] || { rm -f "$tmp"; return; }
  if cmp -s "$tmp" /usr/bin/mimic; then rm -f "$tmp"; ok "已是最新版"; return; fi
  chmod +x "$tmp"; mv -f "$tmp" /usr/bin/mimic
  ok "已更新到最新 mimic"
  [ -f "$CFGDIR/iface" ] && svc restart
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

do_uninstall() {
  printf "%s将删除 mimic 及 %s 下全部配置与服务，确认? [y/N] %s" "$RED" "$CFGDIR" "$R"; read -r a
  case "$a" in y|Y) ;; *) echo "已取消"; return ;; esac
  svc disable
  rmmod mimic 2>/dev/null
  rm -f /lib/modules/*/extra/mimic.ko 2>/dev/null; depmod 2>/dev/null
  case "$PKG" in
    deb)    apt-get purge -y mimic mimic-dkms 2>/dev/null; rm -f /usr/bin/mimic; rm -rf /usr/src/mimic-kmod ;;
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
    printf "  %s5%s) 重启\n"       "$GRN" "$R"
    printf "  %s6%s) 状态\n"       "$CYN" "$R"
    printf "  %s7%s) 完全卸载\n"   "$RED" "$R"
    printf "  %s0%s) 退出\n"       "$GRY" "$R"
    printf "%s请选择: %s" "$B" "$R"; read -r n
    case "$n" in
      1) do_install ;;
      2) cfg_server ;;
      3) cfg_client ;;
      4) view_cfg ;;
      5) svc restart; sleep 1; svc status ;;
      6) svc status ;;
      7) do_uninstall ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
    pause
  done
}

auto_update
menu
