#!/bin/bash

# ============================================================
# Add Node to Prometheus
# Adds a new node_exporter target to prometheus.yml
# Author: ibmaga
# Repository: https://github.com/ibmaga/node-exporter-install
# ============================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults
PROMETHEUS_DIR="/opt/prometheus"
PROMETHEUS_YML="${PROMETHEUS_DIR}/prometheus.yml"
DEFAULT_PORT=9101

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Add a node_exporter target to Prometheus config"
    echo ""
    echo "Options:"
    echo "  -i, --ip IP          Node IP address (required)"
    echo "  -P, --port PORT      Node Exporter port (default: ${DEFAULT_PORT})"
    echo "  -n, --name NAME      Node name for comment (optional)"
    echo "  -d, --dir DIR        Prometheus directory (default: ${PROMETHEUS_DIR})"
    echo "  -l, --list           List current targets"
    echo "  -r, --remove IP      Remove a target by IP"
    echo "  -h, --help           Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --ip 37.139.33.63 --name vk7"
    echo "  $0 -i 37.139.33.63 -P 9100 -n vk7"
    echo "  $0 --list"
    echo "  $0 --remove 37.139.33.63"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_prometheus() {
    if [[ ! -f "$PROMETHEUS_YML" ]]; then
        log_error "Prometheus config not found: $PROMETHEUS_YML"
        log_error "Use --dir to specify Prometheus directory"
        exit 1
    fi
}

list_targets() {
    echo -e "\n${CYAN}Current targets in ${PROMETHEUS_YML}:${NC}\n"
    grep -E "^\s+- '[0-9]" "$PROMETHEUS_YML" | while read -r line; do
        local target
        target=$(echo "$line" | grep -oP "'[^']+'" | tr -d "'")
        local comment
        comment=$(echo "$line" | grep -oP '#.*' || echo "")
        
        local ip port
        ip=$(echo "$target" | cut -d: -f1)
        port=$(echo "$target" | cut -d: -f2)
        
        # Check if reachable
        if curl -sk --max-time 3 "https://${target}/metrics" >/dev/null 2>&1; then
            echo -e "  ${GREEN}●${NC} ${target} ${comment}"
        else
            echo -e "  ${RED}●${NC} ${target} ${comment}"
        fi
    done
    echo ""
    
    # Show Prometheus targets status
    if curl -s http://localhost:9090/api/v1/targets >/dev/null 2>&1; then
        echo -e "${CYAN}Prometheus target health:${NC}\n"
        curl -s http://localhost:9090/api/v1/targets 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('data', {}).get('activeTargets', []):
    instance = t.get('labels', {}).get('instance', 'unknown')
    health = t.get('health', 'unknown')
    color = '\033[0;32m' if health == 'up' else '\033[0;31m'
    print(f'  {color}●\033[0m {instance}: {health}')
" 2>/dev/null || true
        echo ""
    fi
}

add_target() {
    local node_ip=$1
    local port=$2
    local name=$3
    local target="${node_ip}:${port}"
    
    # Check if already exists
    if grep -q "'${node_ip}:" "$PROMETHEUS_YML" 2>/dev/null; then
        local existing
        existing=$(grep "'${node_ip}:" "$PROMETHEUS_YML" | grep -oP "'[^']+'" | tr -d "'")
        log_warn "Node ${node_ip} already exists as target: ${existing}"
        read -rp "$(echo -e "${YELLOW}Replace? (y/N): ${NC}")" choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            remove_target "$node_ip" "quiet"
        else
            log_info "Aborted"
            return 0
        fi
    fi
    
    # Test connectivity first
    log_info "Testing connection to ${target}..."
    if curl -sk --max-time 5 "https://${target}/metrics" | head -1 | grep -q "HELP" 2>/dev/null; then
        log_info "Node is reachable and responding"
    else
        log_warn "Cannot reach ${target} - node may be down or firewall is blocking"
        read -rp "$(echo -e "${YELLOW}Add anyway? (y/N): ${NC}")" choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_info "Aborted"
            return 1
        fi
    fi
    
    # Find the last target line and add after it
    local comment=""
    if [[ -n "$name" ]]; then
        comment=" # ${name}"
    fi
    
    # Find last target entry in vpn-nodes job
    local last_target
    last_target=$(grep -n "^\s*- '[0-9]" "$PROMETHEUS_YML" | tail -1 | cut -d: -f1)
    
    if [[ -n "$last_target" ]]; then
        # Get the indentation from existing target
        local indent
        indent=$(sed -n "${last_target}p" "$PROMETHEUS_YML" | grep -oP '^\s+')
        sed -i "${last_target}a\\${indent}- '${target}'${comment}" "$PROMETHEUS_YML"
    else
        log_error "Could not find targets section in prometheus.yml"
        log_error "Add manually: - '${target}'"
        return 1
    fi
    
    log_info "Added target: ${target}${comment}"
    
    # Restart Prometheus
    restart_prometheus
    
    # Wait and verify
    sleep 5
    if curl -s http://localhost:9090/api/v1/targets 2>/dev/null | grep -q "$node_ip"; then
        local health
        health=$(curl -s http://localhost:9090/api/v1/targets 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('data', {}).get('activeTargets', []):
    if '${node_ip}' in t.get('labels', {}).get('instance', ''):
        print(t.get('health', 'unknown'))
" 2>/dev/null)
        
        if [[ "$health" == "up" ]]; then
            echo -e "\n  ${GREEN}●${NC} ${target} — ${GREEN}UP${NC}\n"
        else
            echo -e "\n  ${YELLOW}●${NC} ${target} — ${YELLOW}${health:-pending}${NC} (may take a few seconds)\n"
        fi
    fi
}

remove_target() {
    local node_ip=$1
    local quiet=$2
    
    if ! grep -q "'${node_ip}:" "$PROMETHEUS_YML" 2>/dev/null; then
        log_error "Target ${node_ip} not found in config"
        return 1
    fi
    
    local target_line
    target_line=$(grep "'${node_ip}:" "$PROMETHEUS_YML")
    
    if [[ "$quiet" != "quiet" ]]; then
        log_warn "Removing: ${target_line}"
        read -rp "$(echo -e "${YELLOW}Confirm? (y/N): ${NC}")" choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_info "Aborted"
            return 0
        fi
    fi
    
    sed -i "/'${node_ip}:/d" "$PROMETHEUS_YML"
    log_info "Removed target: ${node_ip}"
    
    if [[ "$quiet" != "quiet" ]]; then
        restart_prometheus
    fi
}

restart_prometheus() {
    log_info "Restarting Prometheus..."
    
    if command -v docker &>/dev/null; then
        cd "$PROMETHEUS_DIR"
        if docker compose restart prometheus >/dev/null 2>&1; then
            log_info "Prometheus restarted"
        elif docker-compose restart prometheus >/dev/null 2>&1; then
            log_info "Prometheus restarted"
        else
            log_warn "Could not restart Prometheus automatically"
            log_warn "Run: cd ${PROMETHEUS_DIR} && docker compose restart prometheus"
        fi
    else
        log_warn "Docker not found, restart Prometheus manually"
    fi
}

# ============================================================
# Main
# ============================================================

main() {
    local node_ip=""
    local port="$DEFAULT_PORT"
    local name=""
    local action="add"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--ip)
                node_ip="$2"
                shift 2
                ;;
            -P|--port)
                port="$2"
                shift 2
                ;;
            -n|--name)
                name="$2"
                shift 2
                ;;
            -d|--dir)
                PROMETHEUS_DIR="$2"
                PROMETHEUS_YML="${PROMETHEUS_DIR}/prometheus.yml"
                shift 2
                ;;
            -l|--list)
                action="list"
                shift
                ;;
            -r|--remove)
                action="remove"
                node_ip="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                if [[ -z "$node_ip" ]]; then
                    node_ip="$1"
                fi
                shift
                ;;
        esac
    done
    
    check_root
    check_prometheus
    
    case $action in
        list)
            list_targets
            ;;
        remove)
            if [[ -z "$node_ip" ]]; then
                log_error "Specify IP to remove: $0 --remove <IP>"
                exit 1
            fi
            remove_target "$node_ip"
            ;;
        add)
            if [[ -z "$node_ip" ]]; then
                read -rp "$(echo -e "${YELLOW}Node IP: ${NC}")" node_ip
            fi
            if [[ -z "$node_ip" ]]; then
                log_error "Node IP is required"
                show_usage
                exit 1
            fi
            if [[ ! "$node_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                log_error "Invalid IP format: $node_ip"
                exit 1
            fi
            add_target "$node_ip" "$port" "$name"
            ;;
    esac
}

main "$@"
