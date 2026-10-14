#!/usr/bin/env bash
# =====================================================================
#  HAProxy TCP proxy (Docker) - installer & manager for Ubuntu
# =====================================================================
#  * installs Docker + HAProxy (host network, TCP mode)
#  * forwarding rules: add / edit / delete, several servers per rule,
#    balancing modes: roundrobin, failover (backup), leastconn, source
#  * special rules: send a client IP / subnet to another server
#  * every change is checked with "haproxy -c" BEFORE it is applied,
#    the previous config is backed up automatically, graceful reload
#  * config backup / restore / export / import / paste / editor
#  * previously entered values are pre-filled (Enter = keep)
#  * SSH: port, root login, password login, users, keys (with safety checks)
# =====================================================================
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

SCRIPT_VER="3.0.0"

# ---------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------
BASE_DIR="/opt/haproxy"
CONFIG_FILE="$BASE_DIR/haproxy.cfg"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
BACKUP_DIR="$BASE_DIR/backups"
STATE_FILE="$BASE_DIR/.menu_state"        # remembers last entered values
CONTAINER="haproxy"
DEFAULT_IMAGE="haproxy:3.2"               # LTS branch
DEFAULT_STATS_PORT=9000
DEFAULT_MAXCONN=4096
MAX_AUTO_BACKUPS=30                       # automatic backups to keep
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-haproxy-menu.conf"

declare -A STAT=()
RULE_PORTS=()
ADDED_PORTS=()
RULE_SERVERS=(); RULE_SOPTS=(); RULE_MODE="roundrobin"; RULE_DESC=""
WORK=""
TMPD=""
SSH_BAK=""

# ---------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'
    C_B=$'\e[1m';  C_D=$'\e[2m';  C_0=$'\e[0m'
else
    C_R=""; C_G=""; C_Y=""; C_C=""; C_B=""; C_D=""; C_0=""
fi
info()  { echo "${C_G}$*${C_0}"; }
warn()  { echo "${C_Y}$*${C_0}"; }
err()   { echo "${C_R}$*${C_0}"; }
title() { clear; echo "${C_B}==== $* ====${C_0}"; echo; }
pause() { echo; read -r -p "Press Enter to continue..." _; }
trim()  { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
host_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------
is_valid_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local IFS=.
    for o in $ip; do
        # no leading zeros: "010" would be read as octal by the resolver
        [[ $o =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( o <= 255 )) || return 1
    done
    return 0
}

is_valid_hostname() {
    local h=$1
    (( ${#h} <= 253 )) || return 1
    [[ $h =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] || return 1
    [[ ${h##*.} =~ ^[0-9]+$ ]] && return 1   # "1.2.3" is not a hostname
    return 0
}

is_valid_host() {
    if [[ $1 =~ ^[0-9.]+$ ]]; then is_valid_ipv4 "$1"; else is_valid_hostname "$1"; fi
}

is_valid_src() {   # IPv4 or IPv4/mask
    local ip=${1%/*} m
    if [[ $1 == */* ]]; then
        m=${1#*/}
        [[ $m =~ ^[0-9]{1,2}$ ]] && (( 10#$m <= 32 )) || return 1
    fi
    is_valid_ipv4 "$ip"
}

is_valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }

sanitize_desc() {
    local s=$1
    s=${s//[^[:alnum:] ._,:()\/+@=-]/}
    trim "$s"
}

sanitize_label() {
    local s=${1//[^A-Za-z0-9._-]/_}
    echo "${s:-manual}"
}

# ---------------------------------------------------------------------
# Prompts. Default values are PRE-FILLED in the input line and can be
# edited (arrows, Backspace). Enter = accept, Ctrl+U = clear the line.
# ---------------------------------------------------------------------
ask() {   # ask VAR "prompt" [default]
    local __a_var=$1 __a_prompt=$2 __a_def=${3:-} __a_in=""
    if [[ -t 0 ]]; then
        read -e -r -p "$__a_prompt" -i "$__a_def" __a_in
    else
        read -r -p "$__a_prompt" __a_in || { echo "Unexpected end of input." >&2; exit 1; }
        __a_in=${__a_in:-$__a_def}
    fi
    printf -v "$__a_var" '%s' "$(trim "$__a_in")"
}

ask_host() {   # ask_host VAR "prompt" [default] [extra accepted value]
    local __h_var=$1 __h_prompt=$2 __h_def=${3:-} __h_extra=${4:-} __h_in
    while true; do
        ask __h_in "$__h_prompt" "$__h_def"
        __h_in=${__h_in//[[:space:]]/}
        if [[ -n $__h_extra && $__h_in == "$__h_extra" ]] || is_valid_host "$__h_in"; then
            printf -v "$__h_var" '%s' "$__h_in"
            return 0
        fi
        warn "  Invalid address. Enter an IPv4 (1.2.3.4) or a hostname (srv.example.com)."
        __h_def=$__h_in
    done
}

ask_port() {   # ask_port VAR "prompt" [default]
    local __p_var=$1 __p_prompt=$2 __p_def=${3:-} __p_in
    while true; do
        ask __p_in "$__p_prompt" "$__p_def"
        __p_in=${__p_in//[[:space:]]/}
        if is_valid_port "$__p_in"; then
            printf -v "$__p_var" '%s' "$__p_in"
            return 0
        fi
        warn "  Invalid port. Enter a number 1-65535."
        __p_def=$__p_in
    done
}

ask_src() {   # ask_src VAR "prompt" [default]
    local __s_var=$1 __s_prompt=$2 __s_def=${3:-} __s_in
    while true; do
        ask __s_in "$__s_prompt" "$__s_def"
        __s_in=${__s_in//[[:space:]]/}
        if is_valid_src "$__s_in"; then
            printf -v "$__s_var" '%s' "$__s_in"
            return 0
        fi
        warn "  Invalid value. Enter an IPv4 address (1.2.3.4) or a subnet (1.2.3.0/24)."
        __s_def=$__s_in
    done
}

confirm() {   # confirm "question" [Y|N]  -> 0 = yes
    local __q=$1 __d=${2:-N} __c
    if [[ $__d == Y ]]; then read -r -p "$__q [Y/n]: " __c; else read -r -p "$__q [y/N]: " __c; fi
    __c=${__c:-$__d}
    [[ $__c =~ ^[Yy] ]]
}

choose_num() {   # choose_num VAR "prompt" MAX  -> 1 if cancelled (empty input)
    local __cn_var=$1 __cn_prompt=$2 __cn_max=$3 __cn_in
    while true; do
        read -r -p "$__cn_prompt" __cn_in
        __cn_in=$(trim "$__cn_in")
        [[ -z $__cn_in ]] && return 1
        if [[ $__cn_in =~ ^[0-9]+$ ]] && (( 10#$__cn_in >= 1 && 10#$__cn_in <= __cn_max )); then
            printf -v "$__cn_var" '%s' "$((10#$__cn_in))"
            return 0
        fi
        warn "  Enter a number from 1 to $__cn_max (or just Enter to cancel)."
    done
}

# ---------------------------------------------------------------------
# Remembered values
# ---------------------------------------------------------------------
state_get() {
    [[ -f $STATE_FILE ]] || return 0
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); v = $0 } END { if (v != "") print v }' "$STATE_FILE"
}

state_set() {
    mkdir -p "$BASE_DIR"
    local tmp="$TMPD/state.tmp"
    { [[ -f $STATE_FILE ]] && grep -v "^$1=" "$STATE_FILE"; echo "$1=$2"; } > "$tmp"
    cat "$tmp" > "$STATE_FILE"
}

last_addr() {   # last entered backend address, or the first one found in the config
    local a
    a=$(state_get LAST_ADDR)
    if [[ -z $a && -f $CONFIG_FILE ]]; then
        a=$(awk '$1 == "server" { sub(/:[0-9]+$/, "", $3); print $3; exit }' "$CONFIG_FILE")
    fi
    echo "$a"
}

# ---------------------------------------------------------------------
# Config parsing / editing (works on sections, not on blank lines)
# ---------------------------------------------------------------------
AWK_HDR='function is_hdr(s) { return s ~ /^(global|defaults|frontend|backend|listen|userlist|peers|mailers|resolvers|program|http-errors|ring|cache|log-forward|crt-store|traces|acme)([ \t]|$)/ }'

cfg_section() {   # file type name -> prints the section (header included)
    awk -v t="$2" -v n="$3" "$AWK_HDR"'
        is_hdr($0) { insec = ($1 == t && $2 == n) }
        insec' "$1"
}

cfg_has_section() {   # file type name
    awk -v t="$2" -v n="$3" "$AWK_HDR"'
        is_hdr($0) && $1 == t && $2 == n { f = 1 }
        END { exit !f }' "$1"
}

# Replace a section in place with the content of NEWFILE, delete it when
# NEWFILE is empty, append it when the section does not exist yet.
cfg_put_section() {   # file type name [newfile]
    local f=$1 out="$TMPD/put.tmp"
    awk -v t="$2" -v n="$3" -v nf="${4:-}" "$AWK_HDR"'
        function emit(   l) {
            if (nf == "" || done) return
            while ((getline l < nf) > 0) print l
            close(nf); print ""; done = 1
        }
        function flush(   i) { for (i = 1; i <= nb; i++) print buf[i]; nb = 0 }
        is_hdr($0) {
            if (skip) flush()          # comments right above the next section belong to it
            skip = ($1 == t && $2 == n)
            if (skip) { emit(); next }
        }
        skip {
            if ($0 ~ /^#/)            { buf[++nb] = $0; next }
            if ($0 ~ /^[ \t]*$/)      { if (nb) buf[++nb] = $0; next }
            nb = 0; next
        }
        { print }
        END {
            if (skip) flush()
            if (nf != "" && !done) { print ""; emit() }
        }' "$f" | cat -s > "$out" && cat "$out" > "$f"
}

cfg_rule_ports() {   # ports of managed rules (frontend frontend_<port>)
    awk "$AWK_HDR"'
        is_hdr($0) && $1 == "frontend" && $2 ~ /^frontend_[0-9]+$/ { print substr($2, 10) }' "$1" | sort -n
}

fe_default_backend() {   # file port
    cfg_section "$1" frontend "frontend_$2" | awk '$1 == "default_backend" { print $2; exit }'
}

be_servers() {   # file backend -> "name|addr:port|role|extra options"
    cfg_section "$1" backend "$2" | awk '
        $1 == "server" {
            role = ""; extra = ""
            for (i = 4; i <= NF; i++) {
                if ($i ~ /^#/) break
                if ($i == "backup") role = "backup"
                else if ($i != "check") extra = extra (extra == "" ? "" : " ") $i
            }
            print $2 "|" $3 "|" role "|" extra
        }'
}

be_mode() {   # file backend -> roundrobin | failover | leastconn | source | ...
    local sec b
    sec=$(cfg_section "$1" backend "$2")
    if awk '$1 == "server" { for (i = 4; i <= NF; i++) if ($i == "backup") f = 1 } END { exit !f }' <<< "$sec"; then
        echo failover
        return
    fi
    b=$(awk '$1 == "balance" { print $2; exit }' <<< "$sec")
    echo "${b:-roundrobin}"
}

be_desc() {   # file backend
    cfg_section "$1" backend "$2" | awk '$1 == "description" { sub(/^[ \t]*description[ \t]+/, ""); print; exit }'
}

be_ref_count() {   # file backend -> how many default_backend/use_backend lines point to it
    awk -v b="$2" '($1 == "default_backend" || $1 == "use_backend") && $2 == b { c++ } END { print c + 0 }' "$1"
}

fe_specials() {   # file port -> "backend acl source" for every special rule
    cfg_section "$1" frontend "frontend_$2" | awk '
        $1 == "acl" && $3 == "src" {
            s = $4
            for (i = 5; i <= NF && $i !~ /^#/; i++) s = s "," $i
            src[$2] = s
        }
        $1 == "use_backend" && $3 == "if" && NF >= 4 { n++; ub[n] = $2; ua[n] = $4 }
        END { for (i = 1; i <= n; i++) if (ua[i] in src) print ub[i], ua[i], src[ua[i]] }'
}

fe_add_special() {   # file port acl source backend
    local out="$TMPD/spec.tmp"
    awk -v fe="frontend_$2" -v l1="    acl $3 src $4" -v l2="    use_backend $5 if $3" "$AWK_HDR"'
        function ins() { print l1; print l2; done = 1 }
        is_hdr($0) { if (insec && !done) ins(); insec = ($1 == "frontend" && $2 == fe) }
        insec && !done && $1 == "default_backend" { ins() }
        { print }
        END { if (insec && !done) ins() }' "$1" > "$out" && cat "$out" > "$1"
}

fe_del_special() {   # file port acl backend
    local f=$1 fe="frontend_$2" out="$TMPD/spec.tmp" refs
    awk -v fe="$fe" -v a="$3" -v b="$4" "$AWK_HDR"'
        is_hdr($0) { insec = ($1 == "frontend" && $2 == fe) }
        insec && $1 == "use_backend" && $2 == b { for (i = 3; i <= NF; i++) if ($i == a) next }
        { print }' "$f" > "$out" && cat "$out" > "$f"
    # remove the acl only if nothing else in this frontend uses it
    refs=$(cfg_section "$f" frontend "$fe" | awk -v a="$3" '
        $1 != "acl" { for (i = 1; i <= NF; i++) if ($i == a || $i == "!" a) c++ } END { print c + 0 }')
    if (( refs == 0 )); then
        awk -v fe="$fe" -v a="$3" "$AWK_HDR"'
            is_hdr($0) { insec = ($1 == "frontend" && $2 == fe) }
            insec && $1 == "acl" && $2 == a { next }
            { print }' "$f" > "$out" && cat "$out" > "$f"
    fi
}

port_in_cfg() {   # file port -> is this port already bound somewhere in the config
    grep -Eq "^[[:space:]]*bind[[:space:]]+([^[:space:]]*,)?[^[:space:]]*:$2([[:space:],]|$)" "$1"
}

stats_info() {   # [file] -> S_HOST S_PORT S_URI S_USER S_PASS
    local f=${1:-$CONFIG_FILE} sec bind auth
    S_HOST=""; S_PORT=""; S_URI=""; S_USER=""; S_PASS=""
    [[ -f $f ]] || return 1
    sec=$(cfg_section "$f" listen stats)
    [[ -n $sec ]] || return 1
    bind=$(awk '$1 == "bind" { print $2; exit }' <<< "$sec")
    S_PORT=${bind##*:}; S_HOST=${bind%:*}
    S_URI=$(awk '$1 == "stats" && $2 == "uri" { print $3; exit }' <<< "$sec")
    auth=$(awk '$1 == "stats" && $2 == "auth" { print $3; exit }' <<< "$sec")
    S_USER=${auth%%:*}; S_PASS=${auth#*:}
    [[ -n $S_PORT ]]
}

stats_url() { echo "http://$(host_ip):${S_PORT}${S_URI:-/stats}"; }

# ---------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------
gen_base_config() {   # stats_port stats_user stats_pass maxconn
    cat <<EOF
# Generated by HAProxy menu v$SCRIPT_VER ($(date '+%F %T'))
global
    log stdout format raw local0
    maxconn $4
    # after a graceful reload old processes are forced to exit after this time
    hard-stop-after 30m

defaults
    log     global
    mode    tcp
    option  dontlognull
    maxconn $4
    timeout connect 10s
    timeout client  1m
    timeout server  1m

listen stats
    bind *:$1
    mode http
    no log
    stats enable
    stats uri /stats
    stats refresh 5s
    stats auth $2:$3

EOF
}

gen_frontend() {   # port backend
    printf 'frontend frontend_%s\n    mode tcp\n    bind *:%s\n    default_backend %s\n' "$1" "$1" "$2"
}

gen_backend() {   # name   (uses RULE_SERVERS / RULE_SOPTS / RULE_MODE / RULE_DESC)
    local i flag opts
    echo "backend $1"
    echo "    mode tcp"
    [[ -n $RULE_DESC ]] && echo "    description $RULE_DESC"
    if [[ $RULE_MODE == failover ]]; then echo "    balance roundrobin"; else echo "    balance $RULE_MODE"; fi
    for i in "${!RULE_SERVERS[@]}"; do
        flag=""
        [[ $RULE_MODE == failover ]] && (( i > 0 )) && flag=" backup"
        opts=${RULE_SOPTS[i]:-}
        echo "    server srv$((i + 1)) ${RULE_SERVERS[i]} check${opts:+ $opts}${flag}"
    done
}

gen_compose() {   # image
    cat <<EOF
services:
  haproxy:
    image: $1
    container_name: $CONTAINER
    restart: always
    network_mode: host
    user: root
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
EOF
}

rand_pass() { head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-16; }

# ---------------------------------------------------------------------
# Docker / HAProxy runtime
# ---------------------------------------------------------------------
docker_ok()  { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }
compose()    { docker compose -f "$COMPOSE_FILE" "$@"; }
is_running() { [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null) == true ]]; }

haproxy_image() {
    local img=""
    [[ -f $COMPOSE_FILE ]] && img=$(awk '$1 == "image:" { print $2; exit }' "$COMPOSE_FILE")
    echo "${img:-$DEFAULT_IMAGE}"
}

container_started() {
    local t
    t=$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null) && date -d "$t" '+%F %T' 2>/dev/null
}

validate_cfg() {   # file [image]
    local f=$1 img=${2:-$(haproxy_image)} out rc l
    if ! docker_ok; then
        err "Docker is not installed - the config cannot be checked (run 'Install' first)."
        return 1
    fi
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        echo "Pulling $img ..."
        docker pull "$img" || { err "Cannot pull image $img"; return 1; }
    fi
    echo "Checking the config with $img ..."
    out=$(docker run --rm --network host --user root -v "$f:/tmp/check.cfg:ro" "$img" \
          haproxy -c -f /tmp/check.cfg 2>&1)
    rc=$?
    out=${out//\/tmp\/check.cfg/haproxy.cfg}
    if (( rc == 0 )); then
        while IFS= read -r l; do warn "  $l"; done < <(grep -E 'WARNING|ALERT' <<< "$out")
        info "Config is valid."
    else
        echo "$out" | tail -n 25
    fi
    return $rc
}

reload_haproxy() {
    local since
    if [[ ! -f $COMPOSE_FILE ]]; then
        warn "docker-compose.yml not found - HAProxy is not deployed yet (use 'Install' -> keep config)."
        return 1
    fi
    if ! is_running; then
        if confirm "HAProxy is not running. Start it now?" Y; then
            compose up -d && sleep 2 && is_running && info "HAProxy started."
        fi
        return 0
    fi
    # the config is bind-mounted as a single file: if the file was replaced
    # (new inode), the container still sees the old one -> recreate it
    if ! docker exec "$CONTAINER" cat /usr/local/etc/haproxy/haproxy.cfg 2>/dev/null | cmp -s - "$CONFIG_FILE"; then
        warn "The container sees an outdated copy of haproxy.cfg - recreating it (connections will be dropped)..."
        compose up -d --force-recreate && info "HAProxy recreated with the new config."
        return 0
    fi
    since=$(date +%s)
    docker kill -s HUP "$CONTAINER" >/dev/null
    sleep 2
    if docker logs --since "$since" "$CONTAINER" 2>&1 | grep -qiE 'ALERT|Loading failure'; then
        err "HAProxy reported problems while reloading:"
        docker logs --since "$since" "$CONTAINER" 2>&1 | tail -n 20
    else
        info "HAProxy reloaded gracefully (active connections were kept)."
    fi
}

load_stats() {   # fills STAT["backend/server"] = status|cur|total|in|out|lastchg|check
    local host line
    local -a F
    STAT=()
    command -v curl >/dev/null 2>&1 || return 0
    is_running || return 0
    stats_info || return 0
    host=$S_HOST
    [[ -z $host || $host == "*" || $host == "0.0.0.0" || $host == "::" ]] && host=127.0.0.1
    while IFS= read -r line; do
        [[ -z $line || $line == \#* ]] && continue
        IFS=, read -ra F <<< "$line"
        [[ ${F[1]} == FRONTEND || ${F[1]} == BACKEND ]] && continue
        STAT["${F[0]}/${F[1]}"]="${F[17]}|${F[4]}|${F[7]}|${F[8]}|${F[9]}|${F[23]}|${F[36]}"
    done < <(curl -fs --max-time 2 -u "$S_USER:$S_PASS" "http://$host:$S_PORT${S_URI:-/stats};csv" 2>/dev/null)
}

status_badge() {   # "backend/server"
    local v=${STAT[$1]:-} st cur col
    [[ -z $v ]] && return 0
    IFS='|' read -r st cur _ <<< "$v"
    case $st in
        UP)         col=$C_G ;;
        DOWN*)      col=$C_R ;;
        "no check") col=$C_D ;;
        *)          col=$C_Y ;;
    esac
    printf '%s[%s, %s conn]%s' "$col" "$st" "$cur" "$C_0"
}

hbytes() { [[ $1 =~ ^[0-9]+$ ]] && numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "-"; }
hdur() {
    local s=$1
    [[ $s =~ ^[0-9]+$ ]] || { echo "-"; return; }
    if   (( s >= 86400 )); then echo "$((s / 86400))d$((s % 86400 / 3600))h"
    elif (( s >= 3600 ));  then echo "$((s / 3600))h$((s % 3600 / 60))m"
    elif (( s >= 60 ));    then echo "$((s / 60))m"
    else echo "${s}s"; fi
}

# ---------------------------------------------------------------------
# Config transactions: copy -> change -> validate -> backup -> write -> reload
# ---------------------------------------------------------------------
cfg_begin() {
    WORK="$TMPD/work.cfg"
    if [[ -f $CONFIG_FILE ]]; then cp "$CONFIG_FILE" "$WORK"; else : > "$WORK"; fi
}

cfg_begin_from() {   # file  (strips Windows line endings)
    WORK="$TMPD/work.cfg"
    tr -d '\r' < "$1" > "$WORK"
    [[ -s $WORK && -n $(tail -c1 "$WORK") ]] && echo >> "$WORK"
    return 0
}

write_config() {   # src -> CONFIG_FILE, written in place (keeps the inode for the bind mount)
    mkdir -p "$BASE_DIR"
    if [[ -f $CONFIG_FILE ]]; then cat "$1" > "$CONFIG_FILE"; else install -m 600 "$1" "$CONFIG_FILE"; fi
}

open_editor() {
    local ed=${EDITOR:-}
    if [[ -z $ed ]]; then
        for ed in nano mcedit vim vi; do command -v "$ed" >/dev/null 2>&1 && break; done
    fi
    "$ed" "$1"
}

show_diff() {   # old new
    echo "${C_B}Changes (- current, + new), q = close:${C_0}"
    diff -u --label current --label new "$1" "$2" | tail -n +3 |
        awk -v g="$C_G" -v r="$C_R" -v c="$C_C" -v z="$C_0" '
            /^@@/ { print c $0 z; next }
            /^\+/ { print g $0 z; next }
            /^-/  { print r $0 z; next }
            { print }' | less -RFX
}

# returns: 0 = applied, 1 = cancelled / invalid, 2 = nothing changed
cfg_commit() {   # label [diff]
    local label=$1 showdiff=${2:-} c
    if [[ -f $CONFIG_FILE ]] && cmp -s "$WORK" "$CONFIG_FILE"; then
        info "No changes - nothing to apply."
        return 2
    fi
    if [[ -n $showdiff && -f $CONFIG_FILE ]]; then
        show_diff "$CONFIG_FILE" "$WORK"
        confirm "Apply these changes?" Y || { warn "Cancelled, the current config is untouched."; return 1; }
    fi
    while ! validate_cfg "$WORK"; do
        err "The new configuration is INVALID and was NOT applied."
        read -r -p "E = open it in an editor and fix, Enter = discard the changes: " c
        [[ ${c,,} == e ]] || { warn "Changes discarded, the current config is untouched."; return 1; }
        open_editor "$WORK"
    done
    backup_config "auto-before-$label" >/dev/null
    write_config "$WORK"
    info "Configuration saved (the previous version was backed up)."
    reload_haproxy
    return 0
}

# ---------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------
backup_config() {   # label [file]  -> prints the backup path
    local label src=${2:-$CONFIG_FILE} dst
    label=$(sanitize_label "$1")
    [[ -f $src ]] || return 0
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    dst="$BACKUP_DIR/haproxy_$(date +%F_%H-%M-%S)_${label}.cfg"
    [[ -e $dst ]] && dst="${dst%.cfg}_$RANDOM.cfg"
    cp -p "$src" "$dst" || return 1
    # rotate automatic backups only, manual ones are kept forever
    ls -1t "$BACKUP_DIR"/haproxy_*_auto-*.cfg 2>/dev/null | tail -n +$((MAX_AUTO_BACKUPS + 1)) |
        while IFS= read -r old; do rm -f "$old"; done
    echo "$dst"
}

backup_list() {   # newest first; includes *.bak_* files made by the old script version
    ls -1t "$BACKUP_DIR"/*.cfg "$BASE_DIR"/haproxy.cfg.bak_* 2>/dev/null
}

backup_menu() {
    local c
    while true; do
        title "Config backup / restore / replace"
        echo "  Config : $CONFIG_FILE"
        echo "  Backups: $BACKUP_DIR ($(backup_list | grep -c .) files, the last $MAX_AUTO_BACKUPS automatic ones are kept)"
        echo
        echo "  1) Create a backup now"
        echo "  2) Restore from a backup"
        echo "  3) Export (save a copy) to another location"
        echo "  4) Replace the config with a file"
        echo "  5) Replace the config by pasting text"
        echo "  6) Edit the config in a text editor"
        echo "  7) View the config"
        echo "  0) Back"
        echo
        read -r -p "Choice: " c
        case $c in
            1) backup_manual ;;
            2) backup_restore ;;
            3) backup_export ;;
            4) load_from_file && cfg_commit "import" diff; pause ;;
            5) load_from_paste && cfg_commit "paste" diff; pause ;;
            6) config_edit ;;
            7) [[ -f $CONFIG_FILE ]] && less -N "$CONFIG_FILE" ;;
            0|q|x) return ;;
        esac
    done
}

backup_manual() {
    local label p
    [[ -f $CONFIG_FILE ]] || { err "There is no config yet."; pause; return; }
    ask label "Label for this backup (e.g. before-migration): " "manual"
    p=$(backup_config "manual-$label") && info "Saved: $p"
    pause
}

backup_restore() {
    local -a list
    local i n f
    mapfile -t list < <(backup_list)
    (( ${#list[@]} )) || { warn "No backups found."; pause; return; }
    echo "Backups (newest first):"
    for i in "${!list[@]}"; do
        printf '  %2d) %s  %s\n' $((i + 1)) "$(date -r "${list[i]}" '+%F %T')" "$(basename "${list[i]}")"
    done
    echo
    choose_num n "Backup to restore [Enter = cancel]: " "${#list[@]}" || return
    f=${list[n - 1]}
    cfg_begin_from "$f"
    cfg_commit "restore" diff
    pause
}

backup_export() {
    local kind dir name path
    local -a members=(haproxy.cfg)
    [[ -f $CONFIG_FILE ]] || { err "There is no config yet."; pause; return; }
    echo "  1) haproxy.cfg only"
    echo "  2) Full archive (.tar.gz): haproxy.cfg + docker-compose.yml + backups"
    choose_num kind "What to export [1-2, Enter = cancel]: " 2 || return
    dir=$(state_get LAST_EXPORT_DIR); [[ -d $dir ]] || dir=/root
    name="haproxy_$(hostname -s)_$(date +%F)"
    if (( kind == 1 )); then name+=".cfg"; else name+=".tar.gz"; fi
    ask path "Save to (Tab completes paths): " "${dir%/}/$name"
    [[ -n $path ]] || return
    [[ -d $path ]] && path="${path%/}/$name"
    if [[ -e $path ]] && ! confirm "$path already exists. Overwrite?" N; then return; fi
    mkdir -p "$(dirname "$path")"
    if (( kind == 1 )); then
        cp "$CONFIG_FILE" "$path"
    else
        [[ -f $COMPOSE_FILE ]] && members+=(docker-compose.yml)
        [[ -d $BACKUP_DIR ]] && members+=(backups)
        tar -czf "$path" -C "$BASE_DIR" "${members[@]}"
    fi || { err "Export failed."; pause; return; }
    chmod 600 "$path"
    state_set LAST_EXPORT_DIR "$(dirname "$path")"
    info "Exported to $path"
    echo "Download it to your PC with:"
    echo "  scp -P $(ssh_ports | awk '{print $1}') ${SUDO_USER:-root}@$(host_ip):$path ."
    pause
}

load_from_file() {   # -> WORK
    local path dir
    dir=$(state_get LAST_EXPORT_DIR); [[ -n $dir ]] || dir=/root
    echo "Accepted: a haproxy.cfg file or an archive made by 'Export' (.tar.gz)."
    ask path "Path to the file (Tab completes paths): " "${dir%/}/"
    if [[ ! -f $path ]]; then err "File not found: $path"; return 1; fi
    if [[ $path == *.tar.gz || $path == *.tgz ]]; then
        if ! tar -xzOf "$path" haproxy.cfg > "$TMPD/import.cfg" 2>/dev/null; then
            err "haproxy.cfg was not found inside the archive."
            return 1
        fi
        cfg_begin_from "$TMPD/import.cfg"
    else
        cfg_begin_from "$path"
    fi
    info "Loaded $(wc -l < "$WORK") lines from $path"
}

load_from_paste() {   # -> WORK
    local f="$TMPD/paste.cfg" cancelled=0
    echo "Paste the whole haproxy.cfg below. When done press Enter, then Ctrl+D."
    echo "(Ctrl+C = cancel)"
    echo "-----------------------------------------------------------------"
    trap 'cancelled=1' INT
    cat > "$f"
    trap - INT
    echo
    (( cancelled )) && { warn "Cancelled."; return 1; }
    [[ -s $f ]] || { warn "Nothing was pasted."; return 1; }
    cfg_begin_from "$f"
    info "Received $(wc -l < "$WORK") lines."
}

config_edit() {
    [[ -f $CONFIG_FILE ]] || { err "There is no config yet."; pause; return; }
    cfg_begin
    open_editor "$WORK"
    cfg_commit "manual-edit" diff
    pause
}

# ---------------------------------------------------------------------
# Firewall (ufw) - with network_mode: host the ports go through ufw
# ---------------------------------------------------------------------
ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }
ufw_allows() {
    ufw status 2>/dev/null | awk -v p="$1/tcp" -v q="$1" '($1 == p || $1 == q) && $2 == "ALLOW" { f = 1 } END { exit !f }'
}
ufw_offer_allow() {   # ports...
    local p
    local -a need=()
    ufw_active || return 0
    for p in "$@"; do ufw_allows "$p" || need+=("$p"); done
    (( ${#need[@]} )) || return 0
    if confirm "UFW firewall is active. Allow port(s) ${need[*]} (tcp)?" Y; then
        for p in "${need[@]}"; do ufw allow "$p/tcp" >/dev/null && info "  ufw: allowed $p/tcp"; done
    fi
}
ufw_offer_delete() {   # port
    ufw_active && ufw_allows "$1" || return 0
    if confirm "Also remove the UFW rule for $1/tcp?" N; then
        ufw delete allow "$1/tcp" >/dev/null && info "  ufw: removed $1/tcp"
    fi
}

# ---------------------------------------------------------------------
# Rules: display
# ---------------------------------------------------------------------
print_servers() {   # file backend mode prefix
    local name addr role extra tag
    while IFS='|' read -r name addr role extra; do
        tag=""
        [[ $role == backup ]] && tag=" (backup)"
        [[ $3 == failover && $role != backup ]] && tag=" (primary)"
        echo "$4$addr$tag${extra:+ ${C_D}[$extra]${C_0}} $(status_badge "$2/$name")"
    done < <(be_servers "$1" "$2")
}

print_rules() {   # file [nostatus]
    local f=$1 port be mode desc cnt n=0 sbk sacl ssrc others
    mapfile -t RULE_PORTS < <(cfg_rule_ports "$f")
    STAT=()
    [[ -z ${2:-} ]] && load_stats
    (( ${#RULE_PORTS[@]} )) || echo "  (no forwarding rules yet)"
    for port in "${RULE_PORTS[@]}"; do
        n=$((n + 1))
        be=$(fe_default_backend "$f" "$port")
        mode=$(be_mode "$f" "$be")
        desc=$(be_desc "$f" "$be")
        cnt=$(be_servers "$f" "$be" | grep -c .)
        (( cnt > 1 )) || mode=""
        printf '  %s[%d] :%s%s' "$C_B" "$n" "$port" "$C_0"
        [[ -n $mode ]] && printf '   %s%s%s' "$C_C" "$mode" "$C_0"
        [[ -n $desc ]] && printf '   %s# %s%s' "$C_D" "$desc" "$C_0"
        echo
        if [[ -z $be ]]; then echo "        ${C_R}(no default_backend)${C_0}"; fi
        print_servers "$f" "$be" "$mode" "        -> "
        while read -r sbk sacl ssrc; do
            [[ -n $sbk ]] || continue
            echo "        ${C_Y}* client $ssrc:${C_0}"
            print_servers "$f" "$sbk" "" "            -> "
        done < <(fe_specials "$f" "$port")
    done
    others=$(awk "$AWK_HDR"'
        is_hdr($0) && ($1 == "frontend" || $1 == "listen") && $2 !~ /^frontend_[0-9]+$/ && $2 != "stats" {
            printf "%s%s %s", (n++ ? ", " : ""), $1, $2 }' "$f")
    [[ -n $others ]] && echo "  ${C_D}Other sections (edit them manually): $others${C_0}"
    return 0
}

show_health() {
    local k st cur tot bin bout lch chk col
    declare -A addr=()
    load_stats
    if (( ${#STAT[@]} == 0 )); then
        warn "No data: HAProxy is not running or the stats page is not reachable."
        return
    fi
    while read -r k st; do addr[$k]=$st; done < <(awk "$AWK_HDR"'
        is_hdr($0) { b = ($1 == "backend" || $1 == "listen") ? $2 : "" }
        b != "" && $1 == "server" { print b "/" $2, $3 }' "$CONFIG_FILE")
    printf '%s%-34s %-22s %-10s %5s %8s %9s %9s %7s%s\n' "$C_B" "BACKEND/SERVER" "ADDRESS" "STATUS" "CONN" "TOTAL" "IN" "OUT" "SINCE" "$C_0"
    while read -r k; do
        IFS='|' read -r st cur tot bin bout lch chk <<< "${STAT[$k]}"
        case $st in UP) col=$C_G ;; DOWN*) col=$C_R ;; *) col=$C_Y ;; esac
        printf '%-34s %-22s %s%-10s%s %5s %8s %9s %9s %7s\n' "$k" "${addr[$k]:-}" "$col" "$st" "$C_0" \
            "$cur" "$tot" "$(hbytes "$bin")" "$(hbytes "$bout")" "$(hdur "$lch")"
    done < <(printf '%s\n' "${!STAT[@]}" | sort)
    echo
    echo "${C_D}Web stats: $(stats_url)${C_0}"
}

# ---------------------------------------------------------------------
# Rules: input
# ---------------------------------------------------------------------
ssh_ports() { sshd_eff port; }

ask_listen_port() {   # VAR  -> 1 if cancelled
    local __lp_var=$1 __lp_in __lp_busy
    while true; do
        ask __lp_in "  Listen port on this server (e.g. 443, 2096, 50505; Enter = cancel): "
        [[ -z $__lp_in ]] && return 1
        if ! is_valid_port "$__lp_in"; then warn "  Invalid port. Enter a number 1-65535."; continue; fi
        if port_in_cfg "$WORK" "$__lp_in"; then err "  Port $__lp_in is already used in the config."; continue; fi
        if [[ " $(ssh_ports) " == *" $__lp_in "* ]]; then err "  Port $__lp_in is used by SSH."; continue; fi
        __lp_busy=$(ss -Htlnp "( sport = :$__lp_in )" 2>/dev/null | grep -v '"haproxy"')
        if [[ -n $__lp_busy ]]; then
            warn "  Port $__lp_in is already used by another program:"
            echo "$__lp_busy" | sed 's/^/    /'
            confirm "  Use it anyway?" N || continue
        fi
        printf -v "$__lp_var" '%s' "$__lp_in"
        return 0
    done
}

choose_mode() {   # current_mode -> RULE_MODE
    local modes=(roundrobin failover leastconn source) def=1 i n
    for i in "${!modes[@]}"; do [[ ${modes[i]} == "$1" ]] && def=$((i + 1)); done
    echo "  Balancing mode:"
    echo "    1) roundrobin - connections are spread over all servers in turn"
    echo "    2) failover   - one primary server; the others are 'backup' and get"
    echo "                    traffic only while the primary is down"
    echo "    3) leastconn  - a new connection goes to the server with the fewest connections"
    echo "    4) source     - the same client IP always goes to the same server"
    while true; do
        ask n "  Mode [1-4]: " "$def"
        [[ $n =~ ^[1-4]$ ]] && break
    done
    RULE_MODE=${modes[n - 1]}
}

choose_primary() {   # reorders RULE_SERVERS so that the primary is first
    local i p s o
    echo "  Servers (backups are used in this order):"
    for i in "${!RULE_SERVERS[@]}"; do echo "    $((i + 1))) ${RULE_SERVERS[i]}"; done
    while true; do
        ask p "  Primary server number: " "1"
        [[ $p =~ ^[0-9]+$ ]] && (( 10#$p >= 1 && 10#$p <= ${#RULE_SERVERS[@]} )) && break
    done
    p=$((10#$p - 1))
    if (( p > 0 )); then
        s=${RULE_SERVERS[p]}; o=${RULE_SOPTS[p]}
        RULE_SERVERS=("$s" "${RULE_SERVERS[@]:0:p}" "${RULE_SERVERS[@]:p+1}")
        RULE_SOPTS=("$o" "${RULE_SOPTS[@]:0:p}" "${RULE_SOPTS[@]:p+1}")
    fi
}

# Asks for the servers of a backend. Existing servers (edit mode) are
# pre-filled one by one. Result: RULE_SERVERS RULE_SOPTS RULE_MODE RULE_DESC
collect_backend() {   # existing("addr:port|opts" lines) default_addr default_port [cur_mode] [cur_desc]
    local existing=$1 daddr=$2 dport=$3 cur_mode=${4:-roundrobin} cur_desc=${5:-}
    local -a list=()
    local s ap o h p a i n
    RULE_SERVERS=(); RULE_SOPTS=()
    if [[ -n $existing ]]; then
        mapfile -t list <<< "$existing"
        echo "  ${C_D}Current values are pre-filled: Enter = keep, edit to change, '-' = remove the server.${C_0}"
        i=0
        for s in "${list[@]}"; do
            [[ -n $s ]] || continue
            i=$((i + 1))
            ap=${s%%|*}; o=""; [[ $s == *"|"* ]] && o=${s#*|}
            h=${ap%:*}; p=${ap##*:}
            ask_host a "  Server #$i address: " "$h" "-"
            if [[ $a == "-" ]]; then echo "    (removed)"; continue; fi
            ask_port p "  Server #$i port: " "$p"
            RULE_SERVERS+=("$a:$p"); RULE_SOPTS+=("$o")
            daddr=$a; dport=$p
        done
    fi
    while true; do
        if (( ${#RULE_SERVERS[@]} > 0 )); then confirm "  Add another server?" N || break; fi
        n=$(( ${#RULE_SERVERS[@]} + 1 ))
        ask_host a "  Server #$n address: " "$daddr"
        ask_port p "  Server #$n port: " "$dport"
        RULE_SERVERS+=("$a:$p"); RULE_SOPTS+=("")
        daddr=$a; dport=$p
    done
    state_set LAST_ADDR "$daddr"
    if (( ${#RULE_SERVERS[@]} > 1 )); then
        choose_mode "$cur_mode"
        [[ $RULE_MODE == failover ]] && choose_primary
    else
        RULE_MODE=$cur_mode
        [[ $RULE_MODE == failover ]] && RULE_MODE=roundrobin
    fi
    ask RULE_DESC "  Comment (optional, e.g. 'NL main'): " "$cur_desc"
    RULE_DESC=$(sanitize_desc "$RULE_DESC")
}

choose_rule() {   # VAR prompt -> port
    local __cr_var=$1 __cr_n
    if (( ${#RULE_PORTS[@]} == 0 )); then warn "There are no rules yet."; pause; return 1; fi
    choose_num __cr_n "$2 [1-${#RULE_PORTS[@]}, Enter = cancel]: " "${#RULE_PORTS[@]}" || return 1
    printf -v "$__cr_var" '%s' "${RULE_PORTS[__cr_n - 1]}"
}

# ---------------------------------------------------------------------
# Rules: actions (all of them work on $WORK and end with cfg_commit)
# ---------------------------------------------------------------------
rule_add_loop() {   # adds rules to $WORK, the new ports go to ADDED_PORTS
    local lport be
    ADDED_PORTS=()
    while true; do
        echo
        echo "${C_B}New forwarding rule${C_0}  ${C_D}(Tip: Enter keeps the pre-filled value, Ctrl+U clears it)${C_0}"
        ask_listen_port lport || break
        echo "  Where to forward connections from :$lport"
        collect_backend "" "$(last_addr)" "$lport"
        be="backend_$lport"
        gen_frontend "$lport" "$be" > "$TMPD/sec"; cfg_put_section "$WORK" frontend "frontend_$lport" "$TMPD/sec"
        gen_backend "$be" > "$TMPD/sec";          cfg_put_section "$WORK" backend "$be" "$TMPD/sec"
        ADDED_PORTS+=("$lport")
        info "  Rule :$lport -> ${RULE_SERVERS[*]} prepared."
        confirm "Add another rule?" N || break
    done
}

rule_edit() {
    local port be existing
    choose_rule port "Rule to edit" || return
    cfg_begin
    be=$(fe_default_backend "$WORK" "$port")
    if [[ -z $be ]]; then err "frontend_$port has no default_backend - edit it manually."; pause; return; fi
    (( $(be_ref_count "$WORK" "$be") > 1 )) && warn "Note: backend $be is used by several frontends, all of them will change."
    existing=$(be_servers "$WORK" "$be" | awk -F'|' '{ print $2 "|" $4 }')
    echo
    echo "${C_B}Editing rule :$port${C_0} (backend $be)"
    collect_backend "$existing" "$(last_addr)" "$port" "$(be_mode "$WORK" "$be")" "$(be_desc "$WORK" "$be")"
    gen_backend "$be" > "$TMPD/sec"
    cfg_put_section "$WORK" backend "$be" "$TMPD/sec"
    cfg_commit "edit-$port"
    pause
}

rule_delete() {
    local port be bk sacl ssrc nspec=0
    local -a bks=()
    choose_rule port "Rule to delete" || return
    cfg_begin
    be=$(fe_default_backend "$WORK" "$port")
    [[ -n $be ]] && bks+=("$be")
    while read -r bk sacl ssrc; do
        [[ -n $bk ]] && { bks+=("$bk"); nspec=$((nspec + 1)); }
    done < <(fe_specials "$WORK" "$port")
    confirm "Delete rule :$port$( (( nspec )) && echo " and its $nspec special rule(s)")?" N || return
    cfg_put_section "$WORK" frontend "frontend_$port"
    for bk in "${bks[@]}"; do
        (( $(be_ref_count "$WORK" "$bk") == 0 )) && cfg_put_section "$WORK" backend "$bk"
    done
    cfg_commit "delete-$port" && ufw_offer_delete "$port"
    pause
}

special_add() {
    local src targets t port be bk acl sbk sacl ssrc a p defp ok
    local -a sel=()
    (( ${#RULE_PORTS[@]} )) || { warn "Add a normal rule first."; pause; return; }
    echo
    echo "${C_B}Special rule${C_0}: connections from a given client IP/subnet go to another server."
    ask_src src "  Client IP or subnet (e.g. 1.2.3.4 or 1.2.3.0/24): " "$(state_get LAST_SRC)"
    state_set LAST_SRC "$src"
    local tdef=""; (( ${#RULE_PORTS[@]} == 1 )) && tdef="1"
    while true; do
        ask targets "  Apply to rules (numbers separated by spaces, or 'all'): " "$tdef"
        targets=${targets//,/ }
        sel=(); ok=1
        if [[ ${targets,,} == all ]]; then
            sel=("${RULE_PORTS[@]}")
        else
            for t in $targets; do
                if [[ $t =~ ^[0-9]+$ ]] && (( 10#$t >= 1 && 10#$t <= ${#RULE_PORTS[@]} )); then
                    sel+=("${RULE_PORTS[10#$t - 1]}")
                else
                    ok=0
                fi
            done
        fi
        (( ok && ${#sel[@]} )) && break
        warn "  Enter rule numbers from the list, e.g. '1 3', or 'all'."
    done
    cfg_begin
    a=$(last_addr)
    for port in "${sel[@]}"; do
        be=$(fe_default_backend "$WORK" "$port")
        defp=$(be_servers "$WORK" "$be" | awk -F'|' 'NR == 1 { n = split($2, x, ":"); print x[n] }')
        bk=""
        while read -r sbk sacl ssrc; do
            [[ $ssrc == "$src" ]] && bk=$sbk
        done < <(fe_specials "$WORK" "$port")
        echo "  Rule :$port${bk:+ (a special rule for $src already exists - it will be updated)}"
        ask_host a "    Target server address: " "$a"
        ask_port p "    Target server port: " "${defp:-$port}"
        RULE_SERVERS=("$a:$p"); RULE_SOPTS=(""); RULE_MODE=roundrobin
        RULE_DESC=$(sanitize_desc "special: from $src")
        if [[ -z $bk ]]; then
            bk="backend_${port}_src_${src//[.\/]/_}"
            acl="from_${src//[.\/]/_}"
            gen_backend "$bk" > "$TMPD/sec"; cfg_put_section "$WORK" backend "$bk" "$TMPD/sec"
            fe_add_special "$WORK" "$port" "$acl" "$src" "$bk"
        else
            gen_backend "$bk" > "$TMPD/sec"; cfg_put_section "$WORK" backend "$bk" "$TMPD/sec"
        fi
    done
    state_set LAST_ADDR "$a"
    cfg_commit "special"
    pause
}

special_remove() {
    local -a items=()
    local port sbk sacl ssrc i n
    for port in "${RULE_PORTS[@]}"; do
        while read -r sbk sacl ssrc; do
            [[ -n $sbk ]] && items+=("$port|$sbk|$sacl|$ssrc")
        done < <(fe_specials "$CONFIG_FILE" "$port")
    done
    (( ${#items[@]} )) || { warn "There are no special rules."; pause; return; }
    echo "Special rules:"
    for i in "${!items[@]}"; do
        IFS='|' read -r port sbk sacl ssrc <<< "${items[i]}"
        echo "  $((i + 1))) :$port  client $ssrc -> $(be_servers "$CONFIG_FILE" "$sbk" | awk -F'|' '{ printf "%s ", $2 }')"
    done
    choose_num n "Special rule to remove [Enter = cancel]: " "${#items[@]}" || return
    IFS='|' read -r port sbk sacl ssrc <<< "${items[n - 1]}"
    cfg_begin
    fe_del_special "$WORK" "$port" "$sacl" "$sbk"
    (( $(be_ref_count "$WORK" "$sbk") == 0 )) && cfg_put_section "$WORK" backend "$sbk"
    cfg_commit "del-special-$port"
    pause
}

require_config() {
    [[ -f $CONFIG_FILE ]] && return 0
    err "HAProxy config not found ($CONFIG_FILE). Run 'Install' first."
    pause
    return 1
}

rules_menu() {
    local c
    require_config || return
    while true; do
        title "Forwarding rules"
        print_rules "$CONFIG_FILE"
        echo
        echo "  A) Add rule      E) Edit rule      D) Delete rule"
        echo "  S) Add special rule (send a client IP/subnet to another server)"
        echo "  R) Remove special rule"
        echo "  0) Back"
        echo
        read -r -p "Choice: " c
        case ${c,,} in
            a) cfg_begin; rule_add_loop
               (( ${#ADDED_PORTS[@]} )) && cfg_commit "add" && ufw_offer_allow "${ADDED_PORTS[@]}"
               pause ;;
            e) rule_edit ;;
            d) rule_delete ;;
            s) special_add ;;
            r) special_remove ;;
            0|q|x) return ;;
        esac
    done
}

# ---------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------
apt_upgrade() {
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    apt-get update
    apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
}

install_docker() {
    local codename
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    rm -f /etc/apt/sources.list.d/docker.list
    apt-get update || return 1
    apt-get install -y ca-certificates curl gnupg mc || return 1
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || return 1
    chmod a+r /etc/apt/keyrings/docker.asc
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update || return 1
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    systemctl enable --now docker
}

offer_bbr() {
    [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]] && return 0
    confirm "Enable TCP BBR congestion control (usually improves proxy throughput)?" N || return 0
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > /etc/sysctl.d/99-haproxy-bbr.conf
    sysctl -p /etc/sysctl.d/99-haproxy-bbr.conf >/dev/null 2>&1
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; then
        info "BBR enabled."
    else
        warn "Could not enable BBR (the kernel may not support it)."
    fi
}

install_new_config() {   # -> WORK
    local sport suser spass maxc old_maxc re_pass='^[A-Za-z0-9._@%+=!-]{6,}$'
    stats_info "$CONFIG_FILE"   # pre-fill from the existing config, if any
    old_maxc=""
    [[ -f $CONFIG_FILE ]] && old_maxc=$(cfg_section "$CONFIG_FILE" global "" | awk '$1 == "maxconn" { print $2; exit }')
    echo "Statistics web page:"
    while true; do
        ask_port sport "  Stats page port: " "${S_PORT:-$DEFAULT_STATS_PORT}"
        [[ " $(ssh_ports) " == *" $sport "* ]] && { err "  Port $sport is used by SSH."; continue; }
        break
    done
    while true; do
        ask suser "  Stats username: " "${S_USER:-admin}"
        [[ $suser =~ ^[A-Za-z0-9._-]+$ ]] && break
        warn "  Use letters, digits, '.', '_' or '-'."
    done
    while true; do
        ask spass "  Stats password: " "${S_PASS:-$(rand_pass)}"
        [[ $spass =~ $re_pass ]] && break
        warn "  At least 6 characters: letters, digits and . _ @ % + = ! -"
    done
    while true; do
        ask maxc "  Max. simultaneous connections (maxconn): " "${old_maxc:-$DEFAULT_MAXCONN}"
        [[ $maxc =~ ^[1-9][0-9]{1,6}$ ]] && break
        warn "  Enter a number, e.g. 4096."
    done
    WORK="$TMPD/work.cfg"
    gen_base_config "$sport" "$suser" "$spass" "$maxc" > "$WORK"
    if confirm "Add forwarding rules now?" Y; then rule_add_loop; fi
    return 0
}

install_menu() {
    local c img def ok
    title "Install / reinstall HAProxy"
    if confirm "Update system packages first (apt update && apt upgrade)? Recommended on a fresh server" N; then
        apt_upgrade
    fi
    echo
    if docker_ok; then
        info "Docker is already installed: $(docker --version)"
    else
        echo "Installing Docker Engine + Compose plugin..."
        install_docker || { err "Docker installation failed."; pause; return; }
        info "Docker installed: $(docker --version)"
    fi
    mkdir -p "$BASE_DIR" "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    echo
    while true; do
        ask img "HAProxy Docker image (e.g. haproxy:3.2, haproxy:3.4, haproxy:lts): " "$(haproxy_image)"
        [[ $img =~ ^[A-Za-z0-9./:_@-]+$ ]] && break
        warn "  Invalid image name."
    done

    echo
    echo "${C_B}HAProxy configuration${C_0}"
    def=N
    if [[ -f $CONFIG_FILE ]]; then
        echo "  K) Keep the existing config ($(cfg_rule_ports "$CONFIG_FILE" | grep -c .) rules)"
        def=K
    fi
    echo "  N) Create a new config step by step"
    echo "  I) Import a config from a file (or an exported .tar.gz)"
    echo "  P) Paste a config"
    while true; do
        ask c "Choice: " "$def"
        ok=1
        case ${c^^} in
            K) [[ -f $CONFIG_FILE ]] && cfg_begin || ok=0 ;;
            N) install_new_config ;;
            I) load_from_file || ok=0 ;;
            P) load_from_paste || ok=0 ;;
            *) ok=0 ;;
        esac
        (( ok )) && break
    done

    while ! validate_cfg "$WORK" "$img"; do
        read -r -p "E = open the config in an editor and fix, Enter = abort the installation: " c
        [[ ${c,,} == e ]] || { warn "Installation aborted, nothing was changed."; pause; return; }
        open_editor "$WORK"
    done

    if [[ -f $CONFIG_FILE ]] && ! cmp -s "$WORK" "$CONFIG_FILE"; then
        backup_config "auto-before-install" >/dev/null
    fi
    write_config "$WORK"
    gen_compose "$img" > "$TMPD/compose.yml"
    if [[ -f $COMPOSE_FILE ]] && ! cmp -s "$TMPD/compose.yml" "$COMPOSE_FILE"; then
        cp "$COMPOSE_FILE" "$BACKUP_DIR/docker-compose_$(date +%F_%H-%M-%S).yml"
    fi
    cat "$TMPD/compose.yml" > "$COMPOSE_FILE"

    echo "Starting HAProxy..."
    compose up -d --force-recreate
    sleep 2
    if ! is_running; then
        err "HAProxy did not start. Last log lines:"
        docker logs --tail 20 "$CONTAINER" 2>&1
        pause
        return
    fi
    stats_info "$CONFIG_FILE"
    # shellcheck disable=SC2046
    ufw_offer_allow $(cfg_rule_ports "$CONFIG_FILE") ${S_PORT:+"$S_PORT"}
    offer_bbr

    echo
    echo "========================================================="
    info "Installation completed!"
    if [[ -n $S_PORT ]]; then
        echo "HAProxy stats : $(stats_url)"
        echo "Stats login   : $S_USER"
        echo "Stats password: $S_PASS"
    fi
    echo "---------------------------------------------------------"
    print_rules "$CONFIG_FILE" nostatus
    echo "========================================================="
    warn "Don't forget: SSH menu -> add a sudo user and change the SSH port."
    pause
}

# ---------------------------------------------------------------------
# HAProxy service
# ---------------------------------------------------------------------
svc_start() {
    if is_running; then info "HAProxy is already running."; pause; return; fi
    validate_cfg "$CONFIG_FILE" || { err "Fix the config first."; pause; return; }
    compose up -d
    sleep 2
    if is_running; then info "HAProxy started."; else err "HAProxy did not start:"; docker logs --tail 20 "$CONTAINER" 2>&1; fi
    pause
}

svc_stop() {
    if ! is_running; then info "HAProxy is not running."; pause; return; fi
    confirm "Stop HAProxy? All forwarding will stop." N || return
    compose down && info "HAProxy stopped."
    pause
}

svc_restart() {
    validate_cfg "$CONFIG_FILE" || { err "Fix the config first."; pause; return; }
    confirm "Full restart drops all active connections. Continue?" Y || return
    compose up -d --force-recreate && sleep 2
    if is_running; then info "HAProxy restarted."; else err "HAProxy did not start:"; docker logs --tail 20 "$CONTAINER" 2>&1; fi
    pause
}

svc_reload() {
    validate_cfg "$CONFIG_FILE" || { err "The config is invalid - not reloading."; pause; return; }
    reload_haproxy
    pause
}

follow_logs() {
    echo "${C_D}Press Ctrl+C to stop.${C_0}"
    trap ':' INT
    docker logs -f --tail 30 "$CONTAINER"
    trap - INT
}

svc_change_image() {
    local cur new
    cur=$(haproxy_image)
    echo "Current image: $cur"
    echo "Examples: haproxy:3.2 (LTS), haproxy:3.4 (LTS), haproxy:lts, haproxy:3.2-alpine"
    while true; do
        ask new "Image (keep the same name to just pull updates): " "$cur"
        [[ $new =~ ^[A-Za-z0-9./:_@-]+$ ]] && break
        warn "  Invalid image name."
    done
    docker pull "$new" || { err "Cannot pull $new"; pause; return; }
    validate_cfg "$CONFIG_FILE" "$new" || { err "The current config does not work with $new - nothing changed."; pause; return; }
    if [[ $new != "$cur" ]]; then
        cp "$COMPOSE_FILE" "$BACKUP_DIR/docker-compose_$(date +%F_%H-%M-%S).yml"
        sed -i -E "s|^([[:space:]]*image:[[:space:]]*).*|\1$new|" "$COMPOSE_FILE"
    fi
    if confirm "Apply now? If the image changed the container is recreated (connections are dropped)." Y; then
        compose up -d && sleep 2
        is_running && info "HAProxy is running: $(haproxy_image)"
    fi
    pause
}

service_menu() {
    local c
    while true; do
        title "HAProxy service"
        if [[ ! -f $COMPOSE_FILE ]]; then err "HAProxy is not installed yet (use 'Install')."; pause; return; fi
        if is_running; then
            echo "  Status: ${C_G}running${C_0}   image: $(haproxy_image)   started: $(container_started)"
        else
            echo "  Status: ${C_R}stopped${C_0}   image: $(haproxy_image)"
        fi
        echo
        echo "  1) Start"
        echo "  2) Stop"
        echo "  3) Restart (full, active connections are dropped)"
        echo "  4) Reload config (graceful, active connections are kept)"
        echo "  5) Backend servers: health and traffic"
        echo "  6) Show recent logs"
        echo "  7) Follow logs live"
        echo "  8) Change / update HAProxy version (image)"
        echo "  0) Back"
        echo
        read -r -p "Choice: " c
        case $c in
            1) svc_start ;;
            2) svc_stop ;;
            3) svc_restart ;;
            4) svc_reload ;;
            5) show_health; pause ;;
            6) docker logs --tail 60 "$CONTAINER" 2>&1; pause ;;
            7) follow_logs ;;
            8) svc_change_image ;;
            0|q|x) return ;;
        esac
    done
}

# ---------------------------------------------------------------------
# SSH & users
# ---------------------------------------------------------------------
sshd_eff() {   # effective sshd setting (lowercase key), takes Include files into account
    command -v sshd >/dev/null 2>&1 || return 0
    mkdir -p -m 0755 /run/sshd 2>/dev/null
    sshd -T 2>/dev/null | awk -v k="$1" '$1 == k { printf "%s%s", (n++ ? " " : ""), $2 } END { if (n) print "" }'
}

ssh_socket_mode() { systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; }

user_home()    { getent passwd "$1" | cut -d: -f6; }
has_keys()     { local h; h=$(user_home "$1"); [[ -n $h && -s $h/.ssh/authorized_keys ]]; }
is_sudo_user() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel'; }
shell_users()  { awk -F: '($3 == 0 || $3 >= 1000) && $7 ~ /(bash|sh|zsh|fish)$/ { print $1 }' /etc/passwd; }
sudo_users()   { local u; for u in $(shell_users); do [[ $u != root ]] && is_sudo_user "$u" && echo "$u"; done; }

shell_users_desc() {
    local u tags out=""
    for u in $(shell_users); do
        tags=""
        is_sudo_user "$u" && tags+="sudo,"
        has_keys "$u" && tags+="key,"
        out+="$u${tags:+[${tags%,}]} "
    done
    echo "${out% }"
}

sshd_set() {   # Key Value -> written to our drop-in file (first match wins in sshd)
    local main=/etc/ssh/sshd_config
    mkdir -p /etc/ssh/sshd_config.d
    if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$main"; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$main"
    fi
    touch "$SSHD_DROPIN"; chmod 644 "$SSHD_DROPIN"
    sed -i -E "/^[[:space:]]*$1[[:space:]]/Id" "$SSHD_DROPIN"
    echo "$1 $2" >> "$SSHD_DROPIN"
}

ssh_backup() {
    mkdir -p "$BACKUP_DIR/ssh" && chmod 700 "$BACKUP_DIR"
    SSH_BAK="$BACKUP_DIR/ssh/ssh_$(date +%F_%H-%M-%S).tar.gz"
    tar -czf "$SSH_BAK" -C / etc/ssh/sshd_config $( [[ -d /etc/ssh/sshd_config.d ]] && echo etc/ssh/sshd_config.d ) 2>/dev/null
}

ssh_rollback() {
    [[ -f $SSH_BAK ]] || return 1
    rm -f "$SSHD_DROPIN"
    tar -xzf "$SSH_BAK" -C / && warn "SSH settings restored from $SSH_BAK"
}

ssh_restart() {
    systemctl daemon-reload
    if ssh_socket_mode; then
        # Ubuntu 22.10+: the port comes from ssh.socket (generated from sshd_config)
        systemctl restart ssh.socket || systemctl restart ssh
    else
        systemctl restart ssh 2>/dev/null || systemctl restart sshd
    fi
}

ssh_apply() {   # test the config, restart ssh; roll back if the test fails
    mkdir -p -m 0755 /run/sshd
    if ! sshd -t; then
        err "sshd config test failed - rolling back."
        ssh_rollback
        return 1
    fi
    ssh_restart
}

ssh_show_brief() {
    echo "  SSH port(s)       : $(ssh_ports)"
    echo "  Root login        : $(sshd_eff permitrootlogin)"
    echo "  Password login    : $(sshd_eff passwordauthentication)"
    echo "  Socket activation : $(ssh_socket_mode && echo yes || echo no)"
    echo "  Users with shell  : $(shell_users_desc)"
}

ssh_change_port() {
    local cur new busy
    cur=$(ssh_ports); cur=${cur%% *}; cur=${cur:-22}
    echo "Current SSH port: $cur"
    ask_port new "New SSH port: " "$cur"
    [[ $new == "$cur" ]] && { info "Port unchanged."; pause; return; }
    if [[ -f $CONFIG_FILE ]] && port_in_cfg "$CONFIG_FILE" "$new"; then err "Port $new is used by HAProxy."; pause; return; fi
    busy=$(ss -Htlnp "( sport = :$new )" 2>/dev/null)
    if [[ -n $busy ]]; then err "Port $new is already in use:"; echo "$busy"; pause; return; fi
    if ufw_active && ! ufw_allows "$new"; then
        warn "UFW is active: port $new must be allowed, otherwise you will lose SSH access!"
        confirm "Allow $new/tcp in UFW now?" Y && ufw allow "$new/tcp"
    fi
    warn "If your hosting provider has its own firewall, open TCP $new there as well."
    confirm "Change SSH port $cur -> $new?" Y || return
    ssh_backup
    local f
    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -f $f && $f != "$SSHD_DROPIN" ]] && sed -i -E 's/^([[:space:]]*Port[[:space:]])/#\1/I' "$f"
    done
    sshd_set Port "$new"
    ssh_apply || { pause; return; }
    sleep 1
    if ss -Htln "( sport = :$new )" 2>/dev/null | grep -q .; then
        info "SSH now listens on port $new."
        warn "Do NOT close this session! Check the login in a NEW terminal:"
        echo "  ssh -p $new ${SUDO_USER:-root}@$(host_ip)"
        ufw_active && ufw_allows "$cur" && echo "When it works you can close the old port: ufw delete allow $cur/tcp"
    else
        err "Nothing listens on port $new! See: journalctl -u ssh -n 30"
        if confirm "Roll back to the previous SSH settings?" Y; then ssh_rollback && ssh_restart; fi
    fi
    pause
}

ssh_root_login() {
    local cur n val now
    cur=$(sshd_eff permitrootlogin)
    echo "Current PermitRootLogin: ${cur:-unknown}"
    echo "  1) no                - root can't log in over SSH"
    echo "  2) prohibit-password - root can log in with an SSH key only"
    echo "  3) yes               - root can log in with a password or a key"
    choose_num n "Choose [1-3, Enter = cancel]: " 3 || return
    case $n in 1) val=no ;; 2) val=prohibit-password ;; 3) val=yes ;; esac
    if [[ $val != yes && -z $(sudo_users) ]]; then
        warn "There is NO other user with sudo rights - you may lose admin access!"
        warn "Create one first: SSH menu -> 'Add a new sudo user'."
        confirm "Continue anyway?" N || return
    fi
    if [[ $val == prohibit-password ]] && ! has_keys root; then
        warn "root has no SSH keys (/root/.ssh/authorized_keys is empty)."
        confirm "Continue anyway?" N || return
    fi
    ssh_backup
    sshd_set PermitRootLogin "$val"
    if ssh_apply; then
        now=$(sshd_eff permitrootlogin)
        if [[ $now == "$val" ]]; then info "PermitRootLogin is now: $now"; else warn "Effective value is '$now' - another file overrides it (check /etc/ssh/sshd_config*)."; fi
    fi
    pause
}

ssh_password_auth() {
    local cur val u keys=""
    cur=$(sshd_eff passwordauthentication)
    echo "Password login is currently: ${cur:-unknown}"
    if [[ $cur == no ]]; then
        confirm "Enable password login?" N || return
        val=yes
    else
        for u in $(shell_users); do has_keys "$u" && keys+="$u "; done
        if [[ -z $keys ]]; then
            err "No user has SSH keys - disabling passwords would lock you out!"
            confirm "Continue anyway?" N || return
        else
            echo "Users with SSH keys: $keys"
        fi
        confirm "Disable password login (SSH keys only)?" N || return
        val=no
    fi
    ssh_backup
    sshd_set PasswordAuthentication "$val"
    [[ $val == no ]] && sshd_set KbdInteractiveAuthentication no
    ssh_apply && info "PasswordAuthentication is now: $(sshd_eff passwordauthentication)"
    pause
}

ssh_add_key_for() {   # user
    local u=$1 home n key re='^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+'
    local can_copy=0
    home=$(user_home "$u")
    [[ -d $home ]] || { err "Home directory of $u not found."; return 1; }
    [[ $u != root && -s /root/.ssh/authorized_keys ]] && can_copy=1
    echo "  1) Paste a public key (one line: ssh-ed25519 AAAA... comment)"
    (( can_copy )) && echo "  2) Copy root's authorized_keys"
    choose_num n "Choose [Enter = skip]: " $((1 + can_copy)) || return 0
    mkdir -p "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    if (( n == 1 )); then
        read -r -p "Public key: " key
        key=$(trim "$key")
        [[ $key =~ $re ]] || { err "This does not look like an SSH public key."; return 1; }
        grep -qxF "$key" "$home/.ssh/authorized_keys" || echo "$key" >> "$home/.ssh/authorized_keys"
    else
        cat /root/.ssh/authorized_keys "$home/.ssh/authorized_keys" | awk 'NF && !seen[$0]++' > "$TMPD/keys"
        cat "$TMPD/keys" > "$home/.ssh/authorized_keys"
    fi
    chmod 700 "$home/.ssh"; chmod 600 "$home/.ssh/authorized_keys"
    chown -R "$u:" "$home/.ssh"
    info "SSH key(s) installed for $u."
}

ssh_add_user() {
    local u
    echo "Users with a shell: $(shell_users_desc)"
    while true; do
        ask u "New user name (Enter = cancel): " ""
        [[ -z $u ]] && return
        [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
        warn "  Lowercase letters, digits, '-' and '_', starting with a letter."
    done
    if id "$u" >/dev/null 2>&1; then
        warn "User $u already exists."
        if ! is_sudo_user "$u" && confirm "Add $u to the sudo group?" Y; then usermod -aG sudo "$u"; fi
    else
        useradd -m -s /bin/bash -G sudo "$u" || { err "useradd failed."; pause; return; }
        echo "Set a password for $u (it is needed for sudo):"
        until passwd "$u"; do confirm "Try again?" Y || break; done
        info "User $u created and added to the sudo group."
    fi
    confirm "Add an SSH key for $u?" Y && ssh_add_key_for "$u"
    echo
    echo "Check the login in a NEW terminal: ssh -p $(ssh_ports | awk '{print $1}') $u@$(host_ip)"
    pause
}

ssh_add_key() {
    local -a users
    local i n
    mapfile -t users < <(shell_users)
    for i in "${!users[@]}"; do echo "  $((i + 1))) ${users[i]}"; done
    choose_num n "User [Enter = cancel]: " "${#users[@]}" || return
    ssh_add_key_for "${users[n - 1]}"
    pause
}

ssh_menu() {
    local c
    if ! command -v sshd >/dev/null 2>&1; then err "OpenSSH server is not installed."; pause; return; fi
    while true; do
        title "SSH & users"
        ssh_show_brief
        echo
        echo "  1) Change SSH port"
        echo "  2) Root login (PermitRootLogin)"
        echo "  3) Password login on / off"
        echo "  4) Add a new sudo user"
        echo "  5) Add an SSH key to a user"
        echo "  0) Back"
        echo
        read -r -p "Choice: " c
        case $c in
            1) ssh_change_port ;;
            2) ssh_root_login ;;
            3) ssh_password_auth ;;
            4) ssh_add_user ;;
            5) ssh_add_key ;;
            0|q|x) return ;;
        esac
    done
}

# ---------------------------------------------------------------------
# Summary & main menu
# ---------------------------------------------------------------------
show_summary() {
    local u
    title "Current setup"
    echo "${C_B}Server${C_0}"
    echo "  Hostname : $(hostname)"
    echo "  IP       : $(hostname -I 2>/dev/null)"
    echo
    echo "${C_B}HAProxy${C_0}"
    if [[ -f $CONFIG_FILE ]]; then
        if is_running; then echo "  Status   : ${C_G}running${C_0} ($(haproxy_image))"; else echo "  Status   : ${C_R}stopped${C_0}"; fi
        echo "  Config   : $CONFIG_FILE"
        echo "  Backups  : $(backup_list | grep -c .) in $BACKUP_DIR"
        if stats_info; then echo "  Stats    : $(stats_url)   login: $S_USER   password: $S_PASS"; fi
        echo
        print_rules "$CONFIG_FILE"
    else
        echo "  ${C_Y}not installed${C_0}"
    fi
    echo
    echo "${C_B}SSH${C_0}"
    ssh_show_brief
    echo
    if command -v ufw >/dev/null 2>&1; then
        echo "${C_B}Firewall${C_0}: $(ufw status 2>/dev/null | head -n 1)"
    fi
    echo "${C_B}TCP congestion control${C_0}: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    pause
}

header() {
    echo "${C_B}==== HAProxy TCP manager v$SCRIPT_VER ====${C_0}"
    if [[ -f $CONFIG_FILE ]]; then
        local st="${C_R}stopped${C_0}"
        is_running && st="${C_G}running${C_0}"
        echo "  HAProxy: $st   image: $(haproxy_image)   rules: $(cfg_rule_ports "$CONFIG_FILE" | grep -c .)"
    else
        echo "  HAProxy: ${C_Y}not installed${C_0}"
    fi
    echo
}

main_menu() {
    local c
    while true; do
        clear
        header
        echo "  1) Install / reinstall HAProxy"
        echo "  2) Forwarding rules (add / edit / delete / special)"
        echo "  3) Config backup / restore / replace / edit"
        echo "  4) HAProxy service (start / stop / reload / health / logs / version)"
        echo "  5) SSH & users"
        echo "  6) Summary of the current setup"
        echo "  0) Exit"
        echo
        read -r -p "Choice: " c || exit 0
        case $c in
            1) install_menu ;;
            2) rules_menu ;;
            3) backup_menu ;;
            4) service_menu ;;
            5) ssh_menu ;;
            6) show_summary ;;
            0|q|x) exit 0 ;;
        esac
    done
}

main() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1 && [[ -f $0 ]]; then exec sudo -- bash "$0" "$@"; fi
        echo "Please run this script as root."
        exit 1
    fi
    local os_id
    os_id=$(. /etc/os-release 2>/dev/null && echo "$ID")
    if [[ $os_id != ubuntu ]]; then
        echo "This script supports only Ubuntu. Detected OS: ${os_id:-unknown}"
        exit 1
    fi
    TMPD=$(mktemp -d) || exit 1
    trap 'rm -rf "$TMPD"' EXIT
    main_menu
}

# allows "source menu.sh" for testing without starting the menu
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
