#!/bin/sh
#===============================================================================
#  snell-lite · 仅 Snell v6 · 精简安装脚本（Alpine OpenRC / systemd）
#
#  用法：sh snell.sh [install|info|port|restart|log|update|uninstall]
#        无参数：未安装则安装，已安装则显示节点信息并进入菜单
#        安装后可直接用 `snell` 命令打开菜单
#
#  非交互：SB_PORT=443 SB_PSK=xxx SB_MODE=default SB_NAME=HK SB_NONINTERACTIVE=1 sh snell.sh
#  其他：  SB_VER=6.0.0 指定内核版本   SB_SCRIPT_URL=脚本直链（curl|sh 方式装 snell 命令时必填）
#  mode：  default | unshaped | unsafe-raw（客户端必须一致）
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

R=$(printf '\033[31;1m'); G=$(printf '\033[32;1m'); Y=$(printf '\033[33;1m')
B=$(printf '\033[36;1m'); W=$(printf '\033[37;1m'); N=$(printf '\033[0m')
info() { printf '%s\n' "${G}$*${N}"; }
hint() { printf '%s\n' "${Y}$*${N}"; }
warn() { printf '%s\n' "${R}[!] $*${N}"; }
die()  { printf '%s\n' "${R}[x] $*${N}"; exit 1; }
hr()   { printf '%s\n' "${B}------------------------------------------------------------${N}"; }

env_check() {
    [ "$(id -u)" -eq 0 ] || die '请用 root 运行'
    if [ -f /etc/alpine-release ]; then INIT=openrc
    elif command -v systemctl >/dev/null 2>&1; then INIT=systemd
    else die '仅支持 Alpine(OpenRC) 或 systemd'; fi
}

arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo amd64 ;;
        aarch64|arm64) echo aarch64 ;;
        i386|i686)     echo i386 ;;
        *) die "Snell v6 不提供该架构的服务端：$(uname -m)" ;;
    esac
}

get() {  # get <url> <out>
    if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 120 -o "$2" "$1" 2>/dev/null
    else wget -q -T 60 -O "$2" "$1" 2>/dev/null; fi
}

deps() {
    command -v unzip >/dev/null 2>&1 || {
        hint '安装 unzip'
        if command -v apk >/dev/null 2>&1; then apk add --no-cache unzip >/dev/null 2>&1
        elif command -v apt-get >/dev/null 2>&1; then apt-get install -y unzip >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then dnf install -y unzip >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then yum install -y unzip >/dev/null 2>&1; fi
        command -v unzip >/dev/null 2>&1 || die 'unzip 安装失败'
    }
    # 官方二进制是 glibc 动态链接，Alpine 需要兼容层
    [ "$INIT" = openrc ] && apk add --no-cache gcompat libstdc++ >/dev/null 2>&1
    return 0
}

fetch_core() {  # fetch_core <版本>
    _u="https://dl.nssurge.com/snell/snell-server-v$1-linux-$(arch).zip"
    _t=$(mktemp -d) || die 'mktemp 失败'
    hint "下载 $_u"
    get "$_u" "$_t/s.zip" || { rm -rf "$_t"; die '下载失败（版本号或网络问题）'; }
    unzip -oq "$_t/s.zip" -d "$_t" || { rm -rf "$_t"; die '解压失败'; }
    [ -s "$_t/snell-server" ] || { rm -rf "$_t"; die '压缩包内没有 snell-server'; }
    mv -f "$_t/snell-server" "$BIN"; chmod +x "$BIN"; rm -rf "$_t"
}

# ---------- 参数 ----------
rand() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_psk() {
    case "$1" in ''|*[!A-Za-z0-9._~-]*) return 1 ;; esac
    [ ${#1} -ge 8 ]
}

port_in_use() {
    if command -v ss >/dev/null 2>&1; then ss -lntu 2>/dev/null | awk '{print $5}' | grep -q ":$1\$"
    elif command -v netstat >/dev/null 2>&1; then netstat -lntu 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"
    else return 1; fi
}

# ask <提示> <默认值> <变量名> [校验函数]
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
    ask 'Snell 监听端口' "$SB_PORT" PORT valid_port
    ask 'Snell PSK(8位以上字母数字)' "$SB_PSK" PSK valid_psk
    ask '节点名称' "${SB_NAME:-Snell-$(hostname 2>/dev/null || echo node)}" NAME ''
    MODE=$SB_MODE
    port_in_use "$PORT" && warn "端口 $PORT 已被占用，请确认"
    return 0
}

# ---------- 配置与服务 ----------
write_conf() {
    _l="0.0.0.0:$PORT"
    [ -s /proc/net/if_inet6 ] && _l="0.0.0.0:$PORT,[::]:$PORT"
    cat > "$CONF" <<EOF
[snell-server]
listen = $_l
psk = $PSK
mode = $MODE
EOF
    chmod 600 "$CONF"
    printf "NAME='%s'\n" "$(printf '%s' "$NAME" | tr -d "'\"\\\\")" > "$NODE"
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
After=network.target

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

# ---------- 信息 ----------
show_info() {
    [ -s "$CONF" ] || { warn '尚未安装'; return 0; }
    . "$NODE"
    _p=$(sed -n 's/^listen = [^,]*:\([0-9]*\).*/\1/p' "$CONF" | head -1)
    _k=$(sed -n 's/^psk = //p' "$CONF")
    _m=$(sed -n 's/^mode = //p' "$CONF")
    _ip=$(get https://api.ipify.org /dev/stdout | tr -d ' \r\n')
    case "$_ip" in ''|*[!0-9.]*) _ip='<服务器IP>' ;; esac
    _st='未运行'; running && _st='运行中'
    hr
    printf ' 服务状态：%s\n 监听端口：%s\n PSK：%s\n 模式：%s\n' "$_st" "$_p" "$_k" "$_m"
    hr
    printf '%s\n' "${W}Surge 节点（需支持 Snell v6 的 Surge 版本）${N}"
    _x=''; [ "$_m" != default ] && _x=", mode=$_m"
    printf '%s\n' "$NAME = snell, $_ip, $_p, psk=$_k, version=6$_x"
    hr
    hint "别忘了放行防火墙 TCP/UDP $_p"
}

# ---------- 安装 / 改配置 ----------
do_install() {
    env_check; deps
    SB_PORT=${SB_PORT:-}; SB_PSK=${SB_PSK:-}
    input_params
    mkdir -p "$DIR"; chmod 700 "$DIR"
    fetch_core "${SB_VER:-$VER_DEF}"
    write_conf; write_service
    svc stop; sleep 1; svc start; sleep 2
    running || { tail -n 20 "$LOG" 2>/dev/null; die '启动失败；可运行 snell-server --help 核对 v6 配置项'; }
    install_cmd
    info '安装完成'
    show_info
}

# 修改端口 / PSK（沿用现有 mode 与节点名）
do_port() {
    env_check; [ -s "$CONF" ] || die '尚未安装'
    . "$NODE"
    _p=$(sed -n 's/^listen = [^,]*:\([0-9]*\).*/\1/p' "$CONF" | head -1)
    SB_PSK=$(sed -n 's/^psk = //p' "$CONF")
    MODE=$(sed -n 's/^mode = //p' "$CONF")
    ask 'Snell 监听端口' "$_p" PORT valid_port
    ask 'Snell PSK' "$SB_PSK" PSK valid_psk
    port_in_use "$PORT" && [ "$PORT" != "$_p" ] && warn "端口 $PORT 已被占用，请确认"
    write_conf
    svc restart; sleep 2
    running && info '已应用新配置' || die '重启失败，查看 snell log'
    show_info
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
    svc stop
    if [ "$INIT" = openrc ]; then rc-update del snell default >/dev/null 2>&1; rm -f /etc/init.d/snell
    else systemctl disable snell >/dev/null 2>&1; rm -f /etc/systemd/system/snell.service; systemctl daemon-reload; fi
    rm -rf "$DIR"
    info '卸载完成'
    hint "snell 命令保留在 $CMD（方便重装）；彻底删除：rm -f $CMD"
}

# ---------- snell 快捷命令 ----------
# 落真实文件到 /usr/local/bin/snell，与 $DIR 解耦；每次运行自检，丢了就补回
install_cmd() {
    _r=$(readlink -f "$0" 2>/dev/null)
    [ "$_r" = "$CMD" ] && return 0
    _t="$CMD.tmp.$$"
    mkdir -p "${CMD%/*}"
    rm -f "$_t"
    # curl|sh 时 $0 是 sh 本体，必须校验 shebang 才能复制自身
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
        hr
        printf '%s\n' "${B} 1${N}) 查看节点  ${B}2${N}) 修改端口/PSK  ${B}3${N}) 重启  ${B}4${N}) 日志  ${B}5${N}) 更新内核  ${B}6${N}) 卸载  ${B}0${N}) 退出"
        printf '选择: '
        IFS= read -r _c <&3 || _c=0
        case "$_c" in
            1) show_info ;;
            2) do_port ;;
            3) do_restart ;;
            4) do_log ;;
            5) do_update ;;
            6) do_uninstall; exit 0 ;;
            0|'') exit 0 ;;
            *) warn '无效选项' ;;
        esac
    done
}

# ---------- 入口 ----------
# 交互输入统一读 /dev/tty，兼容 curl|sh；无终端（cron/CI）时回落到 stdin
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
    uninstall) do_uninstall ;;
    auto)
        if [ -s "$CONF" ]; then env_check; show_info
        else do_install; fi
        [ "$SB_NONINTERACTIVE" = '1' ] || menu
        ;;
    *) echo "用法: snell [install|info|port|restart|log [n]|update|uninstall]"; exit 1 ;;
esac
