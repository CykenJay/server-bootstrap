#!/usr/bin/env bash

# Only the public wizard entry requires a terminal. The collectors are also tested
# with scripted input; EOF always exits before any system changes are requested.
wizard_read() {
    local prompt=$1 fallback=${2:-}
    local display=${3:-${fallback:-无，必填}}
    printf '%s [默认：%s]：' "$prompt" "$display"
    if ! IFS= read -r ANSWER; then
        printf '\n输入已结束，退出向导。\n'
        exit 0
    fi
    ANSWER=${ANSWER:-$fallback}
}

wizard_choice() {
    local prompt=$1 fallback=$2 allowed=$3
    while :; do
        wizard_read "$prompt" "$fallback"
        if [[ $ANSWER =~ ^[0-9]+$ ]]; then
            case " $allowed " in *" $ANSWER "*) return 0 ;; esac
        fi
        printf '请选择列出的编号。\n'
    done
}

wizard_yes() {
    local prompt=$1
    while :; do
        wizard_read "$prompt（y/n）" n 'n（否）'
        case "$ANSWER" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) printf '请输入 y 或 n；回车选择 n（否）。\n' ;;
        esac
    done
}

wizard_number() {
    local prompt=$1 fallback=$2 minimum=$3 maximum=$4
    while :; do
        wizard_read "$prompt" "$fallback"
        if (number_between "$ANSWER" "$minimum" "$maximum") 2>/dev/null; then
            ANSWER=$((10#$ANSWER)); return 0
        fi
        printf '请输入 %s 到 %s 之间的整数。\n' "$minimum" "$maximum"
    done
}

wizard_addresses() {
    local prompt=$1 display=${2:-无，必填} item valid
    while :; do
        wizard_read "$prompt" '' "$display"
        VALUES=()
        IFS=', ' read -r -a VALUES <<< "$ANSWER"
        valid=1
        for item in ${VALUES[@]+"${VALUES[@]}"}; do
            if ! (validate_address "$item") 2>/dev/null; then valid=0; fi
        done
        if ((valid)); then return 0; fi
        printf '地址格式不正确，请输入 IP 或 CIDR，多个用空格或逗号分隔。\n'
    done
}

wizard_timezone() {
    local current=Etc/UTC link
    if [[ -r /etc/timezone ]]; then
        IFS= read -r current < /etc/timezone || current=Etc/UTC
    elif [[ -L /etc/localtime ]]; then
        link=$(readlink /etc/localtime)
        [[ $link != */zoneinfo/* ]] || current=${link#*/zoneinfo/}
    fi
    [[ -f /usr/share/zoneinfo/$current ]] || current=Etc/UTC
    printf '\n时区：1) 保留当前 %s  2) 北京时间  3) UTC  4) 自定义\n' "$current"
    wizard_choice '选择' 1 '1 2 3 4'
    case "$ANSWER" in
        1) TIMEZONE=$current ;; 2) TIMEZONE=Asia/Shanghai ;; 3) TIMEZONE=Etc/UTC ;;
        4)
            while :; do
                wizard_read '时区名称（例如 Asia/Tokyo）'
                if [[ -n $ANSWER && $ANSWER != /* && $ANSWER != *..* && -f /usr/share/zoneinfo/$ANSWER ]]; then
                    TIMEZONE=$ANSWER; break
                fi
                printf '未找到这个时区，请重新输入。\n'
            done ;;
    esac
}

wizard_ssh() {
    local client=${SSH_CONNECTION%% *}
    printf '\nSSH：回车保留现有端口，输入新端口则额外添加并保留旧端口。\n'
    while :; do
        wizard_read '新增 SSH 端口' '' '不新增，保留现有端口'
        if [[ -z $ANSWER ]]; then SSH_PORT=''; break; fi
        if (number_between "$ANSWER" 1 65535) 2>/dev/null; then SSH_PORT=$((10#$ANSWER)); break; fi
        printf '端口必须为 1–65535。\n'
    done
    printf 'SSH 来源：1) 所有地址  2) 仅当前管理 IP  3) 指定 IP/网段\n'
    wizard_choice '选择' 1 '1 2 3'
    case "$ANSWER" in
        1) SSH_SOURCES=() ;;
        2)
            [[ -n $client ]] || die '无法识别当前 SSH 地址，请通过 SSH 运行向导。'
            validate_address "$client"
            SSH_SOURCES=("$client") ;;
        3)
            while :; do
                wizard_addresses '允许的来源 IP/网段'
                if ((${#VALUES[@]})); then SSH_SOURCES=("${VALUES[@]}"); break; fi
            done ;;
    esac
    printf '\n导入公钥：1) 跳过  2) 服务器上的公钥文件  3) GitHub 账号\n'
    wizard_choice '选择' 1 '1 2 3'
    case "$ANSWER" in
        2)
            while :; do
                wizard_read '公钥文件路径'
                if [[ -n $ANSWER && -f $ANSWER && -r $ANSWER ]]; then KEY_FILE=$ANSWER; break; fi
                printf '文件不存在或不可读。\n'
            done ;;
        3)
            while :; do
                wizard_read 'GitHub 用户名'
                if [[ $ANSWER =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,38}$ ]]; then GITHUB_USER=$ANSWER; break; fi
                printf '用户名格式不正确。\n'
            done ;;
    esac
    if [[ -n $KEY_FILE || -n $GITHUB_USER ]]; then
        while :; do
            wizard_read '安装到哪个已有用户' "${SUDO_USER:-root}"
            if [[ $ANSWER =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] && getent passwd "$ANSWER" >/dev/null; then
                KEY_USER=$ANSWER; break
            fi
            printf '请输入一个已存在的本地用户。\n'
        done
    fi
    AUTH_INFO=${SSH_USER_AUTH:-}
    if (verify_key_session) >/dev/null 2>&1; then
        if wizard_yes '当前会话已通过公钥验证，是否关闭密码及键盘交互认证'; then DISABLE_PASSWORD=1; fi
        if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
            if wizard_yes '是否禁止 root 通过 SSH 登录'; then DISABLE_ROOT=1; fi
        fi
    else
        printf '本次保留登录策略。首次初始化后，用公钥重新登录并运行向导，才能选择关闭密码登录。\n'
    fi
}

wizard_firewall() {
    printf '\n业务端口：1) 只新增 SSH 放行  2) 网站 HTTP/HTTPS  3) 自定义\n'
    wizard_choice '选择' 1 '1 2 3'
    local port proto source
    case "$ANSWER" in
        2) ALLOW_RULES+=(80/tcp 443/tcp) ;;
        3)
            while :; do
                wizard_number '端口号' '' 1 65535; port=$ANSWER
                printf '协议：1) TCP  2) UDP\n'
                wizard_choice '选择' 1 '1 2'
                proto=tcp; [[ $ANSWER == 1 ]] || proto=udp
                while :; do
                    wizard_addresses '允许的来源 IP/网段' '所有地址'
                    if ((${#VALUES[@]} <= 1)); then break; fi
                    printf '每条规则只能填写一个来源，可继续添加规则。\n'
                done
                source=${VALUES[0]:-}
                ALLOW_RULES+=("$port/$proto${source:+@$source}")
                if ! wizard_yes '继续添加端口'; then break; fi
            done ;;
    esac
    wizard_addresses 'Fail2ban 信任 IP/网段' '不添加额外白名单'
    TRUSTED_IPS=(${VALUES[@]+"${VALUES[@]}"})
}

wizard_memory_kib() {
    awk '$1 == "MemTotal:" {print $2; exit}' /proc/meminfo 2>/dev/null
}

wizard_swap_size() {
    local memory_kib suggested=2048
    memory_kib=$(wizard_memory_kib || true)
    if [[ $memory_kib =~ ^[0-9]+$ ]] && ((memory_kib >= 8 * 1024 * 1024 && memory_kib <= 64 * 1024 * 1024)); then
        suggested=$((memory_kib / 2048))
        printf '检测到物理内存约 %s MiB，磁盘 Swap 默认按内存的一半设置，可手动修改。\n' "$((memory_kib / 1024))"
    else
        printf '物理内存不在 8–64 GiB 范围内或无法读取，磁盘 Swap 默认 2048 MiB，可手动修改。\n'
    fi
    wizard_number '磁盘 Swap 大小（MiB）' "$suggested" 256 65536
    SWAP_MIB=$ANSWER
}

wizard_advanced() {
    cat <<'EOF'

高级设置（按需选择）：
  BBR：切换 TCP 拥塞控制算法，影响网络传输。
  交换空间：可选磁盘 Swap、压缩内存 ZRAM，或两者同时使用。
  文件描述符上限：调整进程可同时打开的文件和网络连接数量上限。
  主机名：修改这台服务器的名称。
  DNS：修改域名解析服务器地址，仅支持已有 systemd-resolved 的系统。
  依赖清理：删除 APT 判定不再需要的软件包。
  确认窗口：设置通过新 SSH 连接确认配置的时限，默认 10 分钟。
选择 y 后会逐项询问，不会一次启用全部选项；回车跳过，保持这些设置和默认确认时限。
EOF
    if ! wizard_yes '是否进入高级设置'; then return 0; fi
    if wizard_yes '启用 BBR 拥塞控制'; then BBR=1; fi
    printf '交换空间：\n1) 保持现状\n2) 新建磁盘 Swap\n3) 配置 ZRAM（重启后生效）\n4) ZRAM + 磁盘 Swap（ZRAM 优先，磁盘提供额外容量）\n'
    wizard_choice '选择' 1 '1 2 3 4'
    case "$ANSWER" in
        2) wizard_swap_size ;;
        3) wizard_number 'ZRAM 逻辑容量占物理内存百分比（%）' 50 1 100; ZRAM_PERCENT=$ANSWER ;;
        4)
            wizard_number 'ZRAM 逻辑容量占物理内存百分比（%）' 50 1 100; ZRAM_PERCENT=$ANSWER
            wizard_swap_size
            printf 'ZRAM 优先级为 100，脚本管理的磁盘 Swap 为 10；ZRAM 在手动重启后生效。\n' ;;
    esac
    if wizard_yes '调整文件描述符上限'; then
        wizard_number '文件描述符上限' 65535 1024 1048576; NOFILE=$ANSWER
    fi
    while :; do
        wizard_read '新主机名' '' '保留现有主机名'
        if [[ -z $ANSWER || ( ${#ANSWER} -le 63 && $ANSWER =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ) ]]; then
            HOSTNAME_VALUE=$ANSWER; break
        fi
        printf '请输入不带域名的短主机名，仅包含字母、数字和中划线。\n'
    done
    while :; do
        wizard_addresses 'DNS 地址（仅支持已有 systemd-resolved）' '保留现有 DNS 配置'
        DNS=$(IFS=,; printf '%s' "${VALUES[*]:-}")
        [[ $DNS == */* ]] || break
        printf 'DNS 只能填写 IP 地址，不能填写网段。\n'
    done
    if wizard_yes '清理 APT 判定不再需要的依赖（autoremove）'; then AUTOREMOVE=1; fi
    wizard_number '新连接确认窗口（分钟）' 10 2 60
    ROLLBACK_SECONDS=$((ANSWER * 60))
}

wizard_docker() {
    printf '\nDocker：使用官方软件源安装 Engine、Compose 和 Buildx。\n'
    if wizard_yes '是否安装 Docker（已安装官方版时补齐或更新组件）'; then
        DOCKER_INSTALL=1
        printf '提示：Docker 发布的容器端口可能绕过普通 UFW 入站规则，需要单独控制访问。\n'
    fi
}

wizard_summary() {
    printf '\n========== 执行清单 ==========\n'
    printf '基础：更新已装软件、安装工具、UFW、Fail2ban、安全更新、NTP、日志管理与配置备份\n'
    printf '时区：%s\n' "$TIMEZONE"
    printf 'SSH 端口：保留现有%s\n' "${SSH_PORT:+，新增 $SSH_PORT}"
    printf 'SSH 允许来源：%s\n' "${SSH_SOURCES[*]:-所有地址}"
    printf '新增业务端口：%s\n' "${ALLOW_RULES[*]:-无}"
    printf '已有 UFW 规则将保留；新增 SSH 放行规则优先匹配。\n'
    printf 'Fail2ban：10 分钟内失败 5 次封禁 1 小时；额外白名单：%s\n' "${TRUSTED_IPS[*]:-无}"
    if [[ -n $KEY_FILE || -n $GITHUB_USER ]]; then
        printf '公钥导入：%s → 用户 %s\n' "${KEY_FILE:-GitHub:$GITHUB_USER}" "$KEY_USER"
    else printf '公钥导入：跳过\n'; fi
    if ((DISABLE_PASSWORD)); then printf '密码/键盘交互登录：关闭\n'; else printf '密码登录策略：保留\n'; fi
    if ((DISABLE_ROOT)); then printf 'root SSH 登录：禁止\n'; else printf 'root 登录策略：保留\n'; fi
    if ((DOCKER_INSTALL)); then
        printf 'Docker：安装官方 Engine、Compose、Buildx，并启用开机启动\n'
        printf 'Docker 发布端口需单独限制访问；安装和升级不会随访问配置回滚。\n'
    else printf 'Docker：不执行安装模块\n'; fi
    if ((BBR)); then printf 'BBR：启用\n'; fi
    if ((SWAP_MIB)); then printf '新建 Swap：%s MiB\n' "$SWAP_MIB"; fi
    if ((ZRAM_PERCENT)); then printf 'ZRAM：内存的 %s%%，重启生效\n' "$ZRAM_PERCENT"; fi
    if ((NOFILE)); then printf '文件描述符上限：%s\n' "$NOFILE"; fi
    [[ -z $HOSTNAME_VALUE ]] || printf '主机名：%s\n' "$HOSTNAME_VALUE"
    [[ -z $DNS ]] || printf 'DNS：%s\n' "$DNS"
    if ((AUTOREMOVE)); then printf '删除无用依赖：启用\n'; fi
    printf '访问配置确认窗口：%s 分钟；未确认将自动回滚访问配置\n' "$((ROLLBACK_SECONDS / 60))"
    printf '软件升级和其他系统配置不随访问回滚撤销；不会自动重启。\n'
}

wizard_pending() {
    RUN_ID=$(cat "$STATE_DIR/pending")
    [[ $RUN_ID =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die '待确认运行记录无效。'
    printf '\n检测到尚未确认的初始化：%s\n' "$RUN_ID"
    printf '1) 确认：我已从新 SSH 连接登录\n2) 立即回滚访问配置\n3) 查看状态\n0) 退出，保留定时回滚\n'
    wizard_choice '选择' 0 '0 1 2 3'
    case "$ANSWER" in
        1) COMMAND=confirm ;;
        2)
            COMMAND=cancelled
            if wizard_yes '确认立即恢复此前的 SSH、防火墙和 Fail2ban 配置'; then COMMAND=rollback; fi ;;
        3) COMMAND=status ;;
        0) COMMAND=cancelled ;;
    esac
}

wizard() {
    [[ -t 0 && -t 1 ]] || die '交互向导需要终端。请直接在 SSH 终端运行；仅预览请使用 plan，自动化请显式使用 apply。'
    INTERACTIVE=1
    printf '\nDebian 13 服务器初始化向导\n每项均显示默认值，回车采用；标注“无，必填”的项目需输入。Ctrl+C 随时退出。\n'
    if [[ -r $STATE_DIR/pending ]]; then wizard_pending; return 0; fi
    printf '\n1) 配置并初始化\n2) 仅预览配置（不修改系统）\n3) 查看当前状态\n0) 退出\n'
    wizard_choice '选择' 1 '0 1 2 3'
    local mode=$ANSWER
    case "$mode" in
        0) COMMAND=cancelled; return 0 ;; 3) COMMAND=status; return 0 ;;
        1) require_host ;;
    esac
    SSH_CONNECTION=${SSH_CONNECTION:-}
    wizard_timezone
    wizard_ssh
    wizard_firewall
    wizard_docker
    wizard_advanced
    validate_options
    wizard_summary
    COMMAND=cancelled
    if [[ $mode == 2 ]]; then
        printf '\n预览结束，未修改系统。\n'
    elif wizard_yes '开始执行以上操作'; then
        COMMAND=apply
    else
        printf '\n已取消，未修改系统。\n'
    fi
}

wizard_wait() {
    printf '\n请保留当前终端。在新 SSH 连接中再次运行脚本，选择“确认”。\n'
    if [[ ${SUDO_USER:-root} == root ]]; then
        printf '新连接运行：bash %q\n' "$RUN_DIR/runner/bootstrap.sh"
    else
        printf '新连接运行：sudo --preserve-env=SSH_CONNECTION,SSH_USER_AUTH bash %q\n' "$RUN_DIR/runner/bootstrap.sh"
    fi
    printf '正在等待确认或回滚。Ctrl+C 仅退出等待，不会取消定时回滚。\n'
    while [[ $(cat "$RUN_DIR/status") == pending ]]; do sleep 2; done
    case "$(cat "$RUN_DIR/status")" in
        confirmed) printf '新连接已确认，初始化完成。\n' ;;
        rolled-back) printf '访问配置已回滚；软件升级和其他系统配置保留。\n' ;;
    esac
}
