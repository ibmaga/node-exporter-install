#!/bin/bash

# ============================================================
# Prometheus Node Manager
# Author: ibmaga
# Repository: https://github.com/ibmaga/node-exporter-install
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PROMETHEUS_DIR="/opt/prometheus"
PROMETHEUS_YML="${PROMETHEUS_DIR}/prometheus.yml"
DEFAULT_PORT=9101

log_info() { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}!${NC} $1"; }
log_error() { echo -e "  ${RED}✗${NC} $1"; }

check_root() {
    [[ $EUID -ne 0 ]] && log_error "Run as root" && exit 1
}

check_config() {
    [[ ! -f "$PROMETHEUS_YML" ]] && log_error "Not found: $PROMETHEUS_YML" && exit 1
}

restart_prometheus() {
    echo -ne "  Restarting Prometheus... "
    cd "$PROMETHEUS_DIR"
    if docker compose restart prometheus >/dev/null 2>&1 || docker-compose restart prometheus >/dev/null 2>&1; then
        echo -e "${GREEN}done${NC}"
    else
        echo -e "${RED}failed${NC}"
    fi
}

check_health() {
    curl -sk --max-time 3 "https://$1/metrics" 2>/dev/null | head -1 | grep -q "HELP" && echo "up" || echo "down"
}

# Parse all targets into arrays
load_targets() {
    TARGETS=()
    TARGET_IPS=()
    TARGET_PORTS=()
    TARGET_NAMES=()
    TARGET_LINES=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local linenum target comment ip port
        linenum=$(echo "$line" | cut -d: -f1)
        target=$(echo "$line" | sed "s/^[[:space:]]*[0-9]*:[[:space:]]*- '//;s/'.*//")
        comment=$(echo "$line" | grep -oP '#\s*\K.*' || echo "")
        ip=$(echo "$target" | cut -d: -f1)
        port=$(echo "$target" | cut -d: -f2)

        TARGETS+=("$target")
        TARGET_IPS+=("$ip")
        TARGET_PORTS+=("$port")
        TARGET_NAMES+=("$comment")
        TARGET_LINES+=("$linenum")
    done < <(grep -n -E "^\s+- '[0-9]" "$PROMETHEUS_YML" 2>/dev/null)
}

# ============================================================
# Main list view
# ============================================================

show_list() {
    load_targets
    clear
    echo -e "\n${CYAN}  ══ Prometheus Node Manager ══${NC}\n"

    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        echo -e "  ${DIM}No targets found${NC}\n"
    else
        for i in "${!TARGETS[@]}"; do
            local num=$((i + 1))
            local name="${TARGET_NAMES[$i]}"
            local display_name="${name:-${TARGET_IPS[$i]}}"
            local target="${TARGETS[$i]}"
            printf "  ${BOLD}%2s${NC})  %-20s  ${DIM}%s${NC}\n" "$num" "$display_name" "$target"
        done
    fi

    echo ""
    echo -e "  ${DIM}──────────────────────────────────────${NC}"
    echo -e "  ${BOLD}a${NC} = add    ${BOLD}t${NC} = test all    ${BOLD}q${NC} = quit"
    echo -e "  ${DIM}Enter number to open node details${NC}"
    echo ""
}

# ============================================================
# Node detail view
# ============================================================

show_node() {
    local idx=$1
    local ip="${TARGET_IPS[$idx]}"
    local port="${TARGET_PORTS[$idx]}"
    local name="${TARGET_NAMES[$idx]}"
    local target="${TARGETS[$idx]}"

    clear
    echo -e "\n${CYAN}  ══ Node Details ══${NC}\n"
    echo -e "  ${BOLD}Name:${NC}   ${name:-${DIM}(not set)${NC}}"
    echo -e "  ${BOLD}IP:${NC}     ${ip}"
    echo -e "  ${BOLD}Port:${NC}   ${port}"
    echo -e "  ${BOLD}Target:${NC} ${target}"

    echo -ne "  ${BOLD}Status:${NC} "
    local health
    health=$(check_health "$target")
    if [[ "$health" == "up" ]]; then
        echo -e "${GREEN}● UP${NC}"
    else
        echo -e "${RED}● DOWN${NC}"
    fi

    echo ""
    echo -e "  ${DIM}──────────────────────────────────────${NC}"
    echo -e "  ${BOLD}1${NC} = edit name    ${BOLD}2${NC} = edit IP"
    echo -e "  ${BOLD}3${NC} = edit port    ${BOLD}4${NC} = edit all"
    echo -e "  ${BOLD}d${NC} = delete       ${BOLD}b${NC} = back"
    echo ""

    while true; do
        read -rp "  > " choice
        case $choice in
            1) edit_field "$idx" "name" && return ;;
            2) edit_field "$idx" "ip" && return ;;
            3) edit_field "$idx" "port" && return ;;
            4) edit_all "$idx" && return ;;
            d) delete_node "$idx" && return ;;
            b) return ;;
            *) log_error "Invalid" ;;
        esac
    done
}

edit_field() {
    local idx=$1
    local field=$2
    local ip="${TARGET_IPS[$idx]}"
    local port="${TARGET_PORTS[$idx]}"
    local name="${TARGET_NAMES[$idx]}"
    local linenum="${TARGET_LINES[$idx]}"

    case $field in
        name)
            read -rp "  New name [${name:-none}]: " new_val
            [[ -z "$new_val" ]] && return 0
            name="$new_val"
            ;;
        ip)
            read -rp "  New IP [${ip}]: " new_val
            [[ -z "$new_val" ]] && return 0
            if [[ ! "$new_val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                log_error "Invalid IP"
                return 1
            fi
            ip="$new_val"
            ;;
        port)
            read -rp "  New port [${port}]: " new_val
            [[ -z "$new_val" ]] && return 0
            port="$new_val"
            ;;
    esac

    apply_edit "$linenum" "$ip" "$port" "$name"
}

edit_all() {
    local idx=$1
    local ip="${TARGET_IPS[$idx]}"
    local port="${TARGET_PORTS[$idx]}"
    local name="${TARGET_NAMES[$idx]}"
    local linenum="${TARGET_LINES[$idx]}"

    echo ""
    read -rp "  Name [${name:-none}]: " new_name
    read -rp "  IP [${ip}]: " new_ip
    read -rp "  Port [${port}]: " new_port

    [[ -n "$new_name" ]] && name="$new_name"
    [[ -n "$new_ip" ]] && ip="$new_ip"
    [[ -n "$new_port" ]] && port="$new_port"

    apply_edit "$linenum" "$ip" "$port" "$name"
}

apply_edit() {
    local linenum=$1
    local ip=$2
    local port=$3
    local name=$4
    local target="${ip}:${port}"

    local comment=""
    [[ -n "$name" && "$name" != "none" ]] && comment=" # ${name}"

    local indent
    indent=$(sed -n "${linenum}p" "$PROMETHEUS_YML" | grep -oP '^\s+')

    sed -i "${linenum}s|.*|${indent}- '${target}'${comment}|" "$PROMETHEUS_YML"
    log_info "Saved: ${target}${comment}"
    restart_prometheus
    sleep 1
}

delete_node() {
    local idx=$1
    local target="${TARGETS[$idx]}"
    local name="${TARGET_NAMES[$idx]}"
    local linenum="${TARGET_LINES[$idx]}"

    echo ""
    echo -e "  Delete ${RED}${target}${NC} ${name:+(${name})}?"
    read -rp "  Confirm (y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        sed -i "${linenum}d" "$PROMETHEUS_YML"
        log_info "Deleted"
        restart_prometheus
        sleep 1
    fi
}

# ============================================================
# Add node
# ============================================================

add_node() {
    echo ""
    read -rp "  IP: " ip
    if [[ -z "$ip" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid IP"
        return 1
    fi

    # Check duplicate
    if grep -q "'${ip}:" "$PROMETHEUS_YML" 2>/dev/null; then
        log_warn "Already exists"
        return 1
    fi

    read -rp "  Port [${DEFAULT_PORT}]: " port
    port=${port:-$DEFAULT_PORT}
    read -rp "  Name: " name

    local target="${ip}:${port}"

    echo -ne "  Testing ${target}... "
    local health
    health=$(check_health "$target")
    if [[ "$health" == "up" ]]; then
        echo -e "${GREEN}● UP${NC}"
    else
        echo -e "${RED}● DOWN${NC}"
        read -rp "  Add anyway? (y/N): " choice
        [[ ! "$choice" =~ ^[Yy]$ ]] && return 0
    fi

    local comment=""
    [[ -n "$name" ]] && comment=" # ${name}"

    local last_target
    last_target=$(grep -n "^\s*- '[0-9]" "$PROMETHEUS_YML" | tail -1 | cut -d: -f1)

    if [[ -n "$last_target" ]]; then
        local indent
        indent=$(sed -n "${last_target}p" "$PROMETHEUS_YML" | grep -oP '^\s+')
        sed -i "${last_target}a\\${indent}- '${target}'${comment}" "$PROMETHEUS_YML"
        log_info "Added: ${target}${comment}"
        restart_prometheus
        sleep 1
    else
        log_error "No targets section found"
    fi
}

# ============================================================
# Test all
# ============================================================

test_all() {
    load_targets
    echo ""
    local up=0 down=0
    for i in "${!TARGETS[@]}"; do
        local name="${TARGET_NAMES[$i]}"
        local display="${name:-${TARGET_IPS[$i]}}"
        echo -ne "  ${display} (${TARGETS[$i]}) ... "
        local health
        health=$(check_health "${TARGETS[$i]}")
        if [[ "$health" == "up" ]]; then
            echo -e "${GREEN}● UP${NC}"
            up=$((up + 1))
        else
            echo -e "${RED}● DOWN${NC}"
            down=$((down + 1))
        fi
    done
    echo -e "\n  ${GREEN}UP: ${up}${NC}  ${RED}DOWN: ${down}${NC}"
    echo ""
    read -rp "  Press Enter to continue..."
}

# ============================================================
# CLI mode
# ============================================================

show_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "No arguments = interactive mode"
    echo ""
    echo "Commands:"
    echo "  list                 List targets"
    echo "  add -i IP [-P PORT] [-n NAME]"
    echo "  remove -i IP"
    echo "  test                 Test all"
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 list"
    echo "  $0 add -i 37.139.33.63 -n vk7"
    echo "  $0 remove -i 37.139.33.63"
    echo ""
}

cli_list() {
    load_targets
    echo ""
    for i in "${!TARGETS[@]}"; do
        local num=$((i + 1))
        local name="${TARGET_NAMES[$i]}"
        local target="${TARGETS[$i]}"
        local health
        health=$(check_health "$target")
        local status_icon
        [[ "$health" == "up" ]] && status_icon="${GREEN}●${NC}" || status_icon="${RED}●${NC}"
        printf "  %2s) %-20s %-24s %b\n" "$num" "${name:--}" "$target" "$status_icon"
    done
    echo ""
}

cli_add() {
    local ip=$1 port=$2 name=$3
    [[ -z "$ip" ]] && log_error "Need --ip" && exit 1

    if grep -q "'${ip}:" "$PROMETHEUS_YML" 2>/dev/null; then
        log_warn "Already exists"
        exit 1
    fi

    local target="${ip}:${port}"
    local comment=""
    [[ -n "$name" ]] && comment=" # ${name}"

    local last
    last=$(grep -n "^\s*- '[0-9]" "$PROMETHEUS_YML" | tail -1 | cut -d: -f1)
    if [[ -n "$last" ]]; then
        local indent
        indent=$(sed -n "${last}p" "$PROMETHEUS_YML" | grep -oP '^\s+')
        sed -i "${last}a\\${indent}- '${target}'${comment}" "$PROMETHEUS_YML"
        log_info "Added: ${target}${comment}"
        restart_prometheus
    fi
}

cli_remove() {
    local ip=$1
    [[ -z "$ip" ]] && log_error "Need --ip" && exit 1
    if grep -q "'${ip}:" "$PROMETHEUS_YML" 2>/dev/null; then
        sed -i "/'${ip}:/d" "$PROMETHEUS_YML"
        log_info "Removed: ${ip}"
        restart_prometheus
    else
        log_error "Not found: ${ip}"
    fi
}

# ============================================================
# Main loop
# ============================================================

interactive() {
    check_root
    check_config

    while true; do
        show_list
        read -rp "  > " input

        case $input in
            q|Q|0) echo -e "\n  ${GREEN}Bye${NC}\n" && exit 0 ;;
            a|A) add_node ;;
            t|T) test_all ;;
            *)
                if [[ "$input" =~ ^[0-9]+$ ]]; then
                    local idx=$((input - 1))
                    if [[ $idx -ge 0 && $idx -lt ${#TARGETS[@]} ]]; then
                        show_node "$idx"
                    else
                        log_error "Invalid number"
                        sleep 1
                    fi
                else
                    log_error "Invalid input"
                    sleep 1
                fi
                ;;
        esac
    done
}

main() {
    if [[ $# -eq 0 ]]; then
        interactive
        exit 0
    fi

    local command="" ip="" port="$DEFAULT_PORT" name=""

    case $1 in
        list|add|remove|test) command="$1"; shift ;;
        -h|--help) show_usage; exit 0 ;;
    esac

    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--ip)   ip="$2"; shift 2 ;;
            -P|--port) port="$2"; shift 2 ;;
            -n|--name) name="$2"; shift 2 ;;
            -d|--dir)  PROMETHEUS_DIR="$2"; PROMETHEUS_YML="${PROMETHEUS_DIR}/prometheus.yml"; shift 2 ;;
            -h|--help) show_usage; exit 0 ;;
            *) shift ;;
        esac
    done

    check_root
    check_config

    case $command in
        list)   cli_list ;;
        add)    cli_add "$ip" "$port" "$name" ;;
        remove) cli_remove "$ip" ;;
        test)   load_targets && test_all ;;
        *)      show_usage ;;
    esac
}

main "$@"
