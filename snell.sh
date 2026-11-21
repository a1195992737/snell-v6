#!/bin/sh
#===============================================================================
#  snell-lite · Snell v6 安装与管理脚本
#  支持 Alpine (OpenRC) / Debian (systemd)
#
#  用法：sh snell.sh [install|info|port|restart|log|update|network|firewall|ipv4|uninstall]
#        无参数：未安装则安装，已安装则进入管理菜单
#        安装后可用 `snell` 命令打开菜单
#
#  非交互安装：
#    SB_PORT=443 SB_PSK=xxx SB_NAME=HK SB_NETMODE=ipv4-only SB_NONINTERACTIVE=1 sh snell.sh
#  环境变量：
#    SB_VER=6.0.0        指定内核版本
#    SB_SCRIPT_URL=...   curl|sh 安装 snell 命令时的脚本直链
#    SB_MODE=default     default | unshaped | unsafe-raw（客户端必须一致）
#    SB_NETMODE=dual     dual | prefer-ipv4 | ipv4-only
#
#  系统级 IPv4 优先：glibc 写 gai.conf；musl(Alpine) 切 Snell 仅IPv4 + sysctl 关 IPv6
#  LXC 容器 /proc/sys 只读时仅能保证 Snell 侧仅 IPv4，系统栈需在宿主机关闭。
#===============================================================================

DIR='/etc/snell'
BIN="$DIR/snell-server"
CONF="$DIR/snell-server.conf"
NODE="$DIR/.node"
LOG="$DIR/snell.log"
CMD='/usr/local/bin/snell'
VER_DEF='6.0.0'
SCRIPT_URL="${SB_SCRIPT_URL:-}"
INIT=''
NETMODE='dual'
FW_TYPE=''
NFT_TABLE='snell'
NFT_FILE='/etc/nftables.d/snell.nft'
NFT_CONF='/etc/nftables.conf'
GAI_CONF='/etc/gai.conf'
GAI_BAK="$DIR/gai.conf.bak"
GAI_MARK="$DIR/.gai.managed"
V6_SYSCTL_FILE='/etc/sysctl.d/99-snell-ipv4.conf'
V6_MARK="$DIR/.v6sysctl.managed"

# ---------- 输出样式 ----------
R=$(printf '\033[31;1m'); G=$(printf '\033[32;1m'); Y=$(printf '\033[33;1m')
B=$(printf '\033[36;1m'); W=$(printf '\033[37;1m'); N=$(printf '\033[0m')
info()  { printf '%s\n' "${G}[+]${N} $*"; }
hint()  { printf '%s\n' "${Y}[*]${N} $*"; }
warn()  { printf '%s\n' "${R}[!]${N} $*"; }
die()   { printf '%s\n' "${R}[x]${N} $*"; exit 1; }
hr()    { printf '%s\n' "${B}============================================================${N}"; }
hr2()   { printf '%s\n' "${B}------------------------------------------------------------${N}"; }
title() { printf '\n%s\n' "${B}  $*${N}"; hr2; }

env_check() {
    [ "$(id -u)" -eq 0 ] || die '请用 root 运行'
    if [ -f /etc/alpine-release ]; then INIT=openrc
    elif command -v systemctl >/dev/null 2>&1; then INIT=systemd
    else die '仅支持 Alpine(OpenRC) 或 systemd (Debian/Ubuntu 等)'; fi
}

arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo amd64 ;;
        aarch64|arm64) echo aarch64 ;;
        i386|i686)     echo i386 ;;
        *) die "Snell v6 不提供该架构的服务端：$(uname -m)" ;;
    esac
}

get() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 120 -o "$2" "$1" 2>/dev/null
    else wget -q -T 60 -O "$2" "$1" 2>/dev/null; fi
}

deps() {
    command -v unzip >/dev/null 2>&1 || {
        hint '安装 unzip'
        if command -v apk >/dev/null 2>&1; then apk add --no-cache unzip >/dev/null 2>&1
        elif command -v apt-get >/dev/null 2>&1; then apt-get update >/dev/null 2>&1; apt-get install -y unzip >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then dnf install -y unzip >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then yum install -y unzip >/dev/null 2>&1; fi
        command -v unzip >/dev/null 2>&1 || die 'unzip 安装失败'
    }
    [ "$INIT" = openrc ] && apk add --no-cache gcompat libstdc++ >/dev/null 2>&1
    return 0
}

fetch_core() {
    _u="https://dl.nssurge.com/snell/snell-server-v$1-linux-$(arch).zip"
    _t=$(mktemp -d) || die 'mktemp 失败'
    hint "下载 $_u"
    get "$_u" "$_t/s.zip" || { rm -rf "$_t"; die '下载失败（版本号或网络问题）'; }
    unzip -oq "$_t/s.zip" -d "$_t" || { rm -rf "$_t"; die '解压失败'; }
    [ -s "$_t/snell-server" ] || { rm -rf "$_t"; die '压缩包内没有 snell-server'; }
    mv -f "$_t/snell-server" "$BIN"; chmod +x "$BIN"; rm -rf "$_t"
}

rand() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_psk() {
    case "$1" in ''|*[!A-Za-z0-9._~-]*) return 1 ;; esac
    [ ${#1} -ge 16 ] || return 1
}

port_in_use() {
    if command -v ss >/dev/null 2>&1; then ss -lntu 2>/dev/null | awk '{print $5}' | grep -q ":$1\$"
    elif command -v netstat >/dev/null 2>&1; then netstat -lntu 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"
    else return 1; fi
}

ask() {
    if [ "$SB_NONINTERACTIVE" = '1' ]; then eval "$3=\"\$2\""; return 0; fi
    _i=0
    while :; do
        printf '%s %s[%s]%s: ' "${W}$1${N}" "$Y" "$2" "$N"
        IFS= read -r _in <&3 || _in=''
        [ -z "$_in" ] && _in=$2
        if [ -z "$4" ] || "$4" "$_in"; then eval "$3=\"\$_in\""; return 0; fi
        _i=$((_i+1)); warn '输入无效，请重试'
        [ "$_i" -ge 5 ] && die '输入错误次数过多'
    done
}

input_params() {
    valid_port "$SB_PORT" || SB_PORT=$(( $(od -An -tu2 -N2 /dev/urandom) % 40000 + 20000 ))
    valid_psk "$SB_PSK" || SB_PSK=$(rand 16)
    case "$SB_MODE" in default|unshaped|unsafe-raw) ;; *) SB_MODE=default ;; esac
    case "${SB_NETMODE:-}" in dual|prefer-ipv4|ipv4-only) NETMODE="$SB_NETMODE" ;; *) NETMODE='dual' ;; esac
    ask 'Snell 监听端口' "$SB_PORT" PORT valid_port
    ask 'Snell PSK(16位以上字母数字)' "$SB_PSK" PSK valid_psk
    ask '节点名称' "${SB_NAME:-Snell-$(hostname 2>/dev/null || echo node)}" NAME ''
    MODE="$SB_MODE"
    port_in_use "$PORT" && warn "端口 $PORT 已被占用，请确认"
    return 0
}

# ---------- 网络模式 ----------
netmode_label() {
    case "$1" in
        prefer-ipv4) printf 'IPv4 优先（双栈监听，出口优先 IPv4）' ;;
        ipv4-only)   printf '仅 IPv4（关闭 IPv6 监听与出口）' ;;
        *)           printf '双栈自动（默认）' ;;
    esac
}

netmode_listen() {
    _m="$1"; _p="$2"
    if [ "$_m" = 'ipv4-only' ]; then
        printf '0.0.0.0:%s' "$_p"
    elif [ -s /proc/net/if_inet6 ]; then
        printf '0.0.0.0:%s,[::]:%s' "$_p" "$_p"
    else
        printf '0.0.0.0:%s' "$_p"
    fi
}

netmode_pref() {
    case "$1" in
        prefer-ipv4) printf 'prefer-ipv4' ;;
        ipv4-only)   printf 'ipv4-only' ;;
        *)           printf 'default' ;;
    esac
}

# ---------- 防火墙 ----------
fw_detect() {
    FW_TYPE='none'
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        FW_TYPE='nftables'
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        FW_TYPE='firewalld'
    elif command -v ufw >/dev/null 2>&1 && ufw status >/dev/null 2>&1; then
        FW_TYPE='ufw'
    elif command -v iptables >/dev/null 2>&1; then
        FW_TYPE='iptables'
    fi
}

fw_label() {
    fw_detect
    case "$FW_TYPE" in
        nftables)  printf 'nftables（独立表 inet %s）' "$NFT_TABLE" ;;
        iptables)  printf 'iptables' ;;
        ufw)       printf 'ufw' ;;
        firewalld) printf 'firewalld' ;;
        *)         printf '未检测到可管理的防火墙' ;;
    esac
}

fw_nft_write() {
    _port="$1"
    mkdir -p "${NFT_FILE%/*}" || return 1
    cat > "$NFT_FILE" <<EOF
# Managed by snell.sh - do not edit manually
table inet $NFT_TABLE {
    chain input {
        type filter hook input priority -10 ; policy accept ;
        tcp dport $_port accept
    }
}
EOF
    if [ ! -f "$NFT_CONF" ]; then
        cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.nft"
EOF
    elif ! grep -q '/etc/nftables.d/\*\.nft\|/etc/nftables.d/snell\.nft' "$NFT_CONF" 2>/dev/null; then
        printf '\ninclude "/etc/nftables.d/snell.nft"\n' >> "$NFT_CONF"
    fi
    nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
    nft -f "$NFT_FILE" >/dev/null 2>&1 || return 1
    if [ "$INIT" = openrc ]; then
        rc-update add nftables default >/dev/null 2>&1 || true
    else
        systemctl enable nftables >/dev/null 2>&1 || true
    fi
}

fw_nft_remove() {
    nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
    rm -f "$NFT_FILE"
    [ -f "$NFT_CONF" ] && sed -i '\|/etc/nftables.d/snell\.nft|d' "$NFT_CONF" 2>/dev/null || true
}

fw_ipt_save() {
    mkdir -p /etc/iptables 2>/dev/null || return 1
    if [ "$INIT" = openrc ]; then
        iptables-save > /etc/iptables/rules 2>/dev/null || true
        rc-update add iptables default >/dev/null 2>&1 || true
    else
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        if command -v ip6tables-save >/dev/null 2>&1; then
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        fi
    fi
}

fw_ipt_add() {
    _port="$1"; _m="$2"
    iptables -C INPUT -p tcp --dport "$_port" -j ACCEPT >/dev/null 2>&1 || \
        iptables -I INPUT -p tcp --dport "$_port" -j ACCEPT >/dev/null 2>&1 || return 1
    if [ "$_m" != 'ipv4-only' ] && command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C INPUT -p tcp --dport "$_port" -j ACCEPT >/dev/null 2>&1 || \
            ip6tables -I INPUT -p tcp --dport "$_port" -j ACCEPT >/dev/null 2>&1 || true
    fi
    fw_ipt_save || true
}

fw_ipt_del() {
    _port="$1"
    while iptables -C INPUT -p tcp --dport "$_port" -j ACCEPT >/dev/null 2>&1; do
        iptables -D INPUT -p tcp --dport "$_port" -j ACCEPT >/dev/null 2>&1 || break
    done
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -C INPUT -p tcp --dport "$_port" -j ACCEPT >/dev/null 2>&1; do
            ip6tables -D INPUT -p tcp --dport "$_port" -j ACCEPT >/dev/null 2>&1 || break
        done
    fi
    fw_ipt_save || true
}

fw_open_port() {
    _port="$1"; _m="${2:-$NETMODE}"
    fw_detect
    case "$FW_TYPE" in
        nftables)  fw_nft_write "$_port" && info "nftables 已放行 TCP $_port" || warn "nftables 放行失败" ;;
        iptables)  fw_ipt_add "$_port" "$_m" && info "iptables 已放行 TCP $_port" || warn "iptables 放行失败" ;;
        ufw)       ufw allow "${_port}/tcp" >/dev/null 2>&1 && info "ufw 已放行 TCP $_port" || warn "ufw 放行失败" ;;
        firewalld) firewall-cmd --permanent --add-port="${_port}/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 && info "firewalld 已放行 TCP $_port" || warn "firewalld 放行失败" ;;
        *)         warn "未检测到可管理的防火墙，请手动放行 TCP $_port" ;;
    esac
}

fw_close_port() {
    _port="$1"
    fw_detect
    case "$FW_TYPE" in
        nftables)  fw_nft_remove ;;
        iptables)  fw_ipt_del "$_port" ;;
        ufw)       ufw delete allow "${_port}/tcp" >/dev/null 2>&1 || true ;;
        firewalld) firewall-cmd --permanent --remove-port="${_port}/tcp" >/dev/null 2>&1 || true
                   firewall-cmd --reload >/dev/null 2>&1 || true ;;
        *)         : ;;
    esac
}

# ---------- 系统级 IPv4 优先 ----------
# glibc : 写 /etc/gai.conf 的 precedence 规则（仅影响 getaddrinfo 排序）
# musl  : musl 不读 gai.conf，只能通过 sysctl 关闭 IPv6；LXC 容器 /proc/sys 多为只读，
#         此时退化为「仅把 Snell 切 ipv4-only」并明确告知限制，不静默失败。
_libc_is_musl() {
    [ -f /etc/alpine-release ] && return 0
    command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl && return 0
    return 1
}

ipv6_is_off() {
    [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] || return 1
    [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = '1' ]
}

gai_rule_active() {
    [ -f "$GAI_CONF" ] || return 1
    grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100[[:space:]]*$' "$GAI_CONF" 2>/dev/null
}

# 把已安装的 Snell 强制切为仅 IPv4（关闭系统 IPv6 后 [::] 监听会失败）
_snell_force_ipv4only() {
    [ -s "$CONF" ] || return 0
    _p=$(sed -n 's/^listen = [^,]*:\([0-9]*\).*/\1/p' "$CONF" | head -1)
    _k=$(sed -n 's/^psk = //p' "$CONF")
    _m=$(sed -n 's/^mode = //p' "$CONF")
    . "$NODE" 2>/dev/null
    PORT="$_p"; PSK="$_k"; MODE="$_m"; NETMODE='ipv4-only'
    write_conf
    svc restart >/dev/null 2>&1
}

# musl 分支：sysctl 关闭系统 IPv6 + 联动 Snell
v6_off_apply() {
    mkdir -p "$DIR" || return 1
    if [ ! -e "$V6_MARK" ]; then
        _cur=$(sed -n "s/^NETMODE='\(.*\)'$/\1/p" "$NODE" 2>/dev/null)
        printf 'prev_netmode=%s\n' "${_cur:-dual}" > "$V6_MARK"
    fi
    # 联动：Snell 先切仅 IPv4，保证即使系统 IPv6 关不掉，节点也走 IPv4
    _snell_force_ipv4only
    # 尝试关闭系统 IPv6
    _ok=1
    for _k in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6; do
        sysctl -w "$_k=1" >/dev/null 2>&1 || _ok=0
    done
    if [ "$_ok" -eq 1 ]; then
        mkdir -p "${V6_SYSCTL_FILE%/*}" || true
        cat > "$V6_SYSCTL_FILE" <<EOF
# Managed by snell.sh - musl ignores gai.conf; IPv4 preference via disabling IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
        printf 'sysctl=1\n' >> "$V6_MARK"
        info "已通过 sysctl 关闭系统 IPv6（$(ipv6_is_off && echo 已生效 || echo 待重启生效)）"
        hint "持久化配置：$V6_SYSCTL_FILE"
    else
        printf 'sysctl=0\n' >> "$V6_MARK"
        warn 'sysctl 写入失败：LXC 容器通常将 /proc/sys 挂为只读，无法在容器内关闭系统 IPv6。'
        hint 'Snell 已切为仅 IPv4，节点连接不受影响。'
        hint 'curl ip.sb 仍返回 IPv6 由宿主网络栈决定，容器内有解需在宿主机关闭 IPv6。'
    fi
    return 0
}

v6_off_restore() {
    [ -e "$V6_MARK" ] || { hint '系统 IPv6 设置未由本脚本修改'; return 0; }
    _prev=$(sed -n 's/^prev_netmode=//p' "$V6_MARK" 2>/dev/null)
    _sc=$(sed -n 's/^sysctl=//p' "$V6_MARK" 2>/dev/null)
    [ -z "$_prev" ] && _prev='dual'
    if [ "$_sc" = '1' ]; then
        rm -f "$V6_SYSCTL_FILE"
        for _k in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6; do
            sysctl -w "$_k=0" >/dev/null 2>&1 || true
        done
        info '已恢复系统 IPv6'
    fi
    if [ -s "$CONF" ]; then
        _p=$(sed -n 's/^listen = [^,]*:\([0-9]*\).*/\1/p' "$CONF" | head -1)
        _k=$(sed -n 's/^psk = //p' "$CONF")
        _m=$(sed -n 's/^mode = //p' "$CONF")
        . "$NODE" 2>/dev/null
        PORT="$_p"; PSK="$_k"; MODE="$_m"; NETMODE="$_prev"
        write_conf
        svc restart >/dev/null 2>&1
        info "已恢复 Snell 网络模式：$(netmode_label "$NETMODE")"
    fi
    rm -f "$V6_MARK"
}

gai_apply() {
    if _libc_is_musl; then v6_off_apply; return $?; fi
    mkdir -p "$DIR" || return 1
    # 首次启用前备份原文件，并记录原文件是否存在
    if [ ! -e "$GAI_MARK" ]; then
        if [ -f "$GAI_CONF" ]; then
            cp -p "$GAI_CONF" "$GAI_BAK" || return 1
            printf 'existed\n' > "$GAI_MARK"
        else
            rm -f "$GAI_BAK"
            printf 'created\n' > "$GAI_MARK"
        fi
    fi
    # Debian/Ubuntu 的 gai.conf 默认含被注释的 precedence 行，优先取消注释
    if grep -Eq '^[[:space:]]*#[[:space:]]*precedence[[:space:]]+::ffff:0:0/96' "$GAI_CONF" 2>/dev/null; then
        sed -i -E 's/^[[:space:]]*#[[:space:]]*(precedence[[:space:]]+::ffff:0:0\/96)/\1/' "$GAI_CONF"
    elif ! gai_rule_active; then
        printf '\n# snell.sh: prefer IPv4 over IPv6\nprecedence ::ffff:0:0/96  100\n' >> "$GAI_CONF"
    fi
    gai_rule_active && info "系统级 IPv4 优先已启用（$GAI_CONF）" || { warn '写入后校验失败，请手动检查 gai.conf'; return 1; }
}

gai_restore() {
    if _libc_is_musl; then v6_off_restore; return $?; fi
    [ -e "$GAI_MARK" ] || { hint '系统 IPv4 优先未由本脚本启用'; return 0; }
    if grep -q '^existed$' "$GAI_MARK" 2>/dev/null && [ -f "$GAI_BAK" ]; then
        cp -p "$GAI_BAK" "$GAI_CONF" || return 1
        info '已恢复原始 /etc/gai.conf'
    else
        # 原文件由本脚本创建，直接删除以保持系统干净
        rm -f "$GAI_CONF"
        info '已移除 IPv4 优先规则（删除本脚本创建的 gai.conf）'
    fi
    rm -f "$GAI_MARK" "$GAI_BAK"
}

gai_status_text() {
    if _libc_is_musl; then
        if ipv6_is_off; then
            printf '已启用（sysctl 关闭 IPv6）'
        elif [ -e "$V6_MARK" ]; then
            printf 'Snell 已切仅 IPv4；系统 IPv6 关不掉（容器只读）'
        else
            printf '未启用（musl 无 gai.conf，可 sysctl 关闭 IPv6）'
        fi
    elif gai_rule_active; then
        printf '已启用（gai.conf IPv4 优先）'
    else
        printf '未启用（系统默认）'
    fi
}

# ---------- 配置与服务 ----------
write_conf() {
    _l=$(netmode_listen "$NETMODE" "$PORT")
    _p=$(netmode_pref "$NETMODE")
    cat > "$CONF" <<EOF
[snell-server]
listen = $_l
psk = $PSK
mode = $MODE
dns-ip-preference = $_p
EOF
    chmod 600 "$CONF"
    {
        printf "NAME='%s'\n" "$(printf '%s' "$NAME" | tr -d "'\"\\\\")"
        printf "NETMODE='%s'\n" "$NETMODE"
        printf "PORT='%s'\n" "$PORT"
    } > "$NODE"
}

write_service() {
    if [ "$INIT" = openrc ]; then
        cat > /etc/init.d/snell <<EOF
#!/sbin/openrc-run
description="snell v6"
command="$BIN"
command_args="-c $CONF"
command_background="yes"
pidfile="/run/snell.pid"
output_log="$LOG"
error_log="$LOG"
rc_ulimit="-n 65535"
depend() { need net; }
EOF
        chmod +x /etc/init.d/snell
        rc-update add snell default >/dev/null 2>&1
    else
        cat > /etc/systemd/system/snell.service <<EOF
[Unit]
Description=snell v6
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN -c $CONF
Restart=always
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable snell >/dev/null 2>&1
    fi
}

svc() {
    if [ "$INIT" = openrc ]; then rc-service snell "$1" >/dev/null 2>&1
    else systemctl "$1" snell >/dev/null 2>&1; fi
}

running() {
    if [ "$INIT" = openrc ]; then rc-service snell status >/dev/null 2>&1
    else systemctl is-active --quiet snell; fi
}

# ---------- 信息展示 ----------
show_info() {
    [ -s "$CONF" ] || { warn '尚未安装'; return 0; }
    . "$NODE"
    NETMODE=${NETMODE:-dual}
    _p=$(sed -n 's/^listen = [^,]*:\([0-9]*\).*/\1/p' "$CONF" | head -1)
    _k=$(sed -n 's/^psk = //p' "$CONF")
    _m=$(sed -n 's/^mode = //p' "$CONF")
    _ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || wget -q -T 5 -O - https://api.ipify.org 2>/dev/null)
    _ip=$(printf '%s' "$_ip" | tr -d ' \r\n')
    case "$_ip" in ''|*[!0-9.]*) _ip='<服务器IP>' ;; esac
    _st='未运行'; running && _st='运行中'
    hr
    printf '  %s\n' "${B}节点概览${N}"
    hr2
    printf '  服务状态 : %s\n' "$_st"
    printf '  监听端口 : %s\n' "$_p"
    printf '  PSK      : %s\n' "$_k"
    printf '  协议模式 : %s\n' "$_m"
    printf '  网络模式 : %s\n' "$(netmode_label "$NETMODE")"
    printf '  IPv4优先 : %s\n' "$(gai_status_text)"
    printf '  防火墙   : %s\n' "$(fw_label)"
    hr2
    printf '  %s\n' "${W}Surge 节点（需支持 Snell v6 的 Surge 版本）${N}"
    _x=''; [ "$_m" != default ] && _x=", mode=$_m"
    printf '  %s = snell, %s, %s, psk=%s, version=6$_x\n' "$NAME" "$_ip" "$_p" "$_k"
    hr
    hint "TCP $_p 已尝试自动放行；如仍不通请检查云厂商安全组"
}

show_firewall() {
    hr
    printf '  %s\n' "${B}防火墙状态${N}"
    hr2
    printf '  检测类型 : %s\n' "$(fw_label)"
    if [ -s "$NODE" ]; then
        . "$NODE"
        printf '  放行端口 : %s/tcp\n' "${PORT:-未知}"
    fi
    hr2
    hint "放行规则会在节点安装/改端口时自动更新"
}

show_system_ipv4() {
    hr
    printf '  %s\n' "${B}系统级 IPv4 优先${N}"
    hr2
    printf '  当前状态 : %s\n' "$(gai_status_text)"
    if _libc_is_musl; then
        printf '  sysctl   : %s\n' "$V6_SYSCTL_FILE"
    else
        printf '  配置文件 : %s\n' "$GAI_CONF"
    fi
    hr2
    if _libc_is_musl; then
        hint 'musl 不读 gai.conf；启用时会把 Snell 切为仅 IPv4，并尝试 sysctl 关闭系统 IPv6。'
        if ! ipv6_is_off; then
            warn '若处于 LXC 容器，/proc/sys 多为只读，系统 IPv6 可能关不掉。'
            hint '此时 Snell 已仅 IPv4，节点不受影响；curl ip.sb 返回 IPv6 需在宿主机关闭 IPv6。'
        fi
    elif gai_rule_active; then
        hint '已生效：系统会优先用 IPv4 连接同时具备 A/AAAA 记录的域名。'
        hint '验证：curl ip.sb 应返回 IPv4；curl -6 ip.sb 可强制 IPv6 作对照。'
    else
        hint '当前使用系统默认地址选择（多数 glibc 系统 IPv6 优先）。'
    fi
}

# ---------- 安装 / 配置 ----------
do_install() {
    env_check; deps
    SB_PORT=${SB_PORT:-}; SB_PSK=${SB_PSK:-}
    input_params
    mkdir -p "$DIR"; chmod 700 "$DIR"
    fetch_core "${SB_VER:-$VER_DEF}"
    write_conf; write_service
    fw_open_port "$PORT" "$NETMODE"
    svc stop; sleep 1; svc start; sleep 2
    running || { tail -n 20 "$LOG" 2>/dev/null; die '启动失败；可运行 snell-server --help 核对 v6 配置项'; }
    install_cmd
    info '安装完成'
    show_info
}

do_port() {
    env_check; [ -s "$CONF" ] || die '尚未安装'
    . "$NODE"
    NETMODE=${NETMODE:-dual}
    _oldp=$(sed -n 's/^listen = [^,]*:\([0-9]*\).*/\1/p' "$CONF" | head -1)
    SB_PSK=$(sed -n 's/^psk = //p' "$CONF")
    MODE=$(sed -n 's/^mode = //p' "$CONF")
    ask 'Snell 监听端口' "$_oldp" PORT valid_port
    ask 'Snell PSK' "$SB_PSK" PSK valid_psk
    port_in_use "$PORT" && [ "$PORT" != "$_oldp" ] && warn "端口 $PORT 已被占用，请确认"
    if [ "$PORT" != "$_oldp" ]; then
        fw_close_port "$_oldp"
        fw_open_port "$PORT" "$NETMODE"
    fi
    write_conf
    svc restart; sleep 2
    running && info '已应用新配置' || die '重启失败，查看 snell log'
    show_info
}

do_network() {
    env_check; [ -s "$CONF" ] || { warn '尚未安装'; return 0; }
    . "$NODE"
    NETMODE=${NETMODE:-dual}
    title '网络模式设置'
    printf '  当前模式 : %s\n\n' "$(netmode_label "$NETMODE")"
    printf '  %s1%s) 双栈自动（同时监听 IPv4 + IPv6）\n' "$Y" "$N"
    printf '  %s2%s) IPv4 优先（双栈监听，出口优先 IPv4）\n' "$Y" "$N"
    printf '  %s3%s) 仅 IPv4（关闭 IPv6 监听与出口）\n' "$Y" "$N"
    printf '  %s0%s) 返回\n' "$Y" "$N"
    hr2
    printf '选择: '
    IFS= read -r _c <&3 || _c=0
    case "$_c" in
        1) _new='dual' ;;
        2) _new='prefer-ipv4' ;;
        3) _new='ipv4-only' ;;
        0|'') return 0 ;;
        *) warn '无效选项'; return 1 ;;
    esac
    [ "$_new" = "$NETMODE" ] && { info '模式未变化'; return 0; }
    NETMODE="$_new"
    PORT=$(sed -n 's/^listen = [^,]*:\([0-9]*\).*/\1/p' "$CONF" | head -1)
    PSK=$(sed -n 's/^psk = //p' "$CONF")
    MODE=$(sed -n 's/^mode = //p' "$CONF")
    write_conf
    fw_open_port "$PORT" "$NETMODE"
    svc restart; sleep 2
    running && info "已切换为: $(netmode_label "$NETMODE")" || warn '重启失败，请查看日志'
}

do_system_ipv4() {
    env_check
    title '系统级 IPv4 优先'
    printf '  当前状态 : %s\n\n' "$(gai_status_text)"
    if _libc_is_musl; then
        printf '  %s1%s) 启用（Snell 切仅IPv4 + sysctl 关闭 IPv6）\n' "$Y" "$N"
        printf '  %s2%s) 恢复原状\n' "$Y" "$N"
    else
        printf '  %s1%s) 启用 IPv4 优先（写入 /etc/gai.conf）\n' "$Y" "$N"
        printf '  %s2%s) 恢复系统默认\n' "$Y" "$N"
    fi
    printf '  %s0%s) 返回\n' "$Y" "$N"
    hr2
    printf '选择: '
    IFS= read -r _c <&3 || _c=0
    case "$_c" in
        1) gai_apply ;;
        2) gai_restore ;;
        0|'') return 0 ;;
        *) warn '无效选项'; return 1 ;;
    esac
    show_system_ipv4
}

do_restart() {
    env_check; [ -s "$CONF" ] || die '尚未安装'
    svc restart; sleep 2
    running && info '已重启' || die '重启失败，查看 snell log'
}

do_log() {
    env_check
    if [ "$INIT" = openrc ]; then tail -n "${1:-40}" "$LOG" 2>/dev/null || warn '暂无日志'
    else journalctl -u snell -n "${1:-40}" --no-pager; fi
}

do_update() {
    env_check; [ -x "$BIN" ] || die '尚未安装'
    cp -f "$BIN" "$BIN.bak"
    fetch_core "${SB_VER:-$VER_DEF}"
    svc restart; sleep 2
    if running; then rm -f "$BIN.bak"; info '内核已更新'
    else mv -f "$BIN.bak" "$BIN"; svc restart; die '新版本启动失败，已回滚'; fi
}

do_uninstall() {
    env_check
    if [ "$SB_NONINTERACTIVE" != '1' ]; then
        printf '%s' "${R}确认卸载 snell 及全部配置？[y/N]: ${N}"
        IFS= read -r _c <&3 || _c=''
        case "$_c" in y|Y|yes) ;; *) info '已取消'; return 0 ;; esac
    fi
    [ -s "$NODE" ] && . "$NODE"
    [ -n "${PORT:-}" ] && fw_close_port "$PORT"
    gai_restore || true
    svc stop
    if [ "$INIT" = openrc ]; then rc-update del snell default >/dev/null 2>&1; rm -f /etc/init.d/snell
    else systemctl disable snell >/dev/null 2>&1; rm -f /etc/systemd/system/snell.service; systemctl daemon-reload; fi
    rm -rf "$DIR"
    info '卸载完成（防火墙规则与系统 IPv4 优先设置已清理）'
    hint "snell 命令保留在 $CMD；彻底删除：rm -f $CMD"
}

# ---------- 快捷命令 ----------
install_cmd() {
    _r=$(readlink -f "$0" 2>/dev/null)
    [ "$_r" = "$CMD" ] && return 0
    _t="$CMD.tmp.$$"
    mkdir -p "${CMD%/*}"
    rm -f "$_t"
    if [ -f "$_r" ] && head -n1 "$_r" 2>/dev/null | grep -q '^#!'; then
        cp -f "$_r" "$_t"
    elif [ -n "$SCRIPT_URL" ]; then
        get "$SCRIPT_URL" "$_t"
    fi
    if head -n1 "$_t" 2>/dev/null | grep -q '^#!'; then
        [ -L "$CMD" ] && rm -f "$CMD"
        mv -f "$_t" "$CMD" && chmod 755 "$CMD"
        command -v snell >/dev/null 2>&1 || { cp -f "$CMD" /usr/bin/snell && chmod 755 /usr/bin/snell; }
        info '已安装快捷命令：snell'
    else
        rm -f "$_t"
        warn '未能安装 snell 命令：请先保存脚本再执行 sh snell.sh，或设置 SB_SCRIPT_URL'
    fi
}

selfheal() {
    [ "$(id -u)" -eq 0 ] && [ ! -x "$CMD" ] && [ -s "$CONF" ] && install_cmd >/dev/null 2>&1
    return 0
}

menu() {
    while :; do
        printf '\n'
        hr
        printf '  %sSnell v6 管理菜单%s\n' "${B}${W}" "$N"
        hr2
        printf '  %s1%s) 查看节点       %s2%s) 改端口/PSK    %s3%s) 重启服务\n' "$Y" "$N" "$Y" "$N" "$Y" "$N"
        printf '  %s4%s) 查看日志       %s5%s) 更新内核      %s6%s) 网络模式\n' "$Y" "$N" "$Y" "$N" "$Y" "$N"
        printf '  %s7%s) 防火墙状态     %s8%s) IPv4优先      %s9%s) 卸载\n' "$Y" "$N" "$Y" "$N" "$Y" "$N"
        printf '  %s0%s) 退出\n' "$Y" "$N"
        hr2
        printf '选择: '
        IFS= read -r _c <&3 || _c=0
        case "$_c" in
            1) show_info ;;
            2) do_port ;;
            3) do_restart ;;
            4) do_log ;;
            5) do_update ;;
            6) do_network ;;
            7) show_firewall ;;
            8) do_system_ipv4 ;;
            9) do_uninstall; exit 0 ;;
            0|'') exit 0 ;;
            *) warn '无效选项' ;;
        esac
    done
}

# ---------- 入口 ----------
if ( : </dev/tty ) 2>/dev/null; then exec 3</dev/tty; else exec 3<&0; fi

A=${1:-auto}
env_check
[ "$A" = install ] || [ "$A" = uninstall ] || selfheal
case "$A" in
    install)   do_install ;;
    info)      show_info ;;
    port)      do_port ;;
    restart)   do_restart ;;
    log)       do_log "$2" ;;
    update)    do_update ;;
    network)   do_network ;;
    firewall)  show_firewall ;;
    ipv4)      do_system_ipv4 ;;
    ipv4-on)   env_check; gai_apply; show_system_ipv4 ;;
    ipv4-off)  env_check; gai_restore; show_system_ipv4 ;;
    uninstall) do_uninstall ;;
    auto)
        if [ -s "$CONF" ]; then env_check; show_info
        else do_install; fi
        [ "$SB_NONINTERACTIVE" = '1' ] || menu
        ;;
    *) echo "用法: snell [install|info|port|restart|log [n]|update|network|firewall|ipv4|ipv4-on|ipv4-off|uninstall]"; exit 1 ;;
esac
