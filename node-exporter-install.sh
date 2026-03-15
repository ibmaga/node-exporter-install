#!/bin/bash

# ============================================================
# Node Exporter Install Script with TLS
# For Prometheus monitoring of VPN nodes
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
NODE_EXPORTER_VERSION="1.10.2"
DEFAULT_PORT=9101
CONFIG_DIR="/etc/node_exporter"
BINARY_PATH="/usr/local/bin/node_exporter"

# ============================================================
# Functions
# ============================================================

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║   Node Exporter Installer with TLS          ║"
    echo "║   For Prometheus VPN Node Monitoring         ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}[STEP]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

detect_ip() {
    # Try multiple methods to detect public IP
    local ip=""
    for service in "ifconfig.me" "icanhazip.com" "ipecho.net/plain" "api.ipify.org"; do
        ip=$(curl -s --max-time 5 "$service" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

detect_hostname() {
    hostname
}

check_existing() {
    if systemctl is-active --quiet node_exporter 2>/dev/null; then
        log_warn "Node Exporter is already running!"
        echo ""
        echo -e "  Status: ${GREEN}active${NC}"
        
        local current_port
        current_port=$(ss -tlnp | grep node_exporter | awk '{print $4}' | grep -oP '\d+$' | head -1)
        if [[ -n "$current_port" ]]; then
            echo -e "  Port:   ${CYAN}$current_port${NC}"
        fi
        
        local current_version
        current_version=$($BINARY_PATH --version 2>&1 | head -1 | grep -oP 'version \K[0-9.]+' || echo "unknown")
        echo -e "  Version: ${CYAN}$current_version${NC}"
        echo ""
        
        read -rp "$(echo -e "${YELLOW}Reinstall? (y/N): ${NC}")" choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_info "Aborted"
            exit 0
        fi
        
        log_info "Stopping existing node_exporter..."
        systemctl stop node_exporter
        systemctl disable node_exporter 2>/dev/null || true
    fi
}

find_free_port() {
    local port=$1
    while ss -tlnp | grep -q ":${port} " 2>/dev/null; do
        log_warn "Port $port is busy, trying $((port + 1))..."
        port=$((port + 1))
    done
    echo "$port"
}

install_binary() {
    log_step "Installing Node Exporter v${NODE_EXPORTER_VERSION}..."
    
    cd /tmp
    local archive="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
    local url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${archive}"
    
    if [[ -f "$archive" ]]; then
        log_info "Archive already exists, skipping download"
    else
        log_info "Downloading..."
        wget -q --show-progress "$url" -O "$archive"
    fi
    
    tar xzf "$archive"
    cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    
    # Cleanup
    rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"
    
    log_info "Binary installed: $BINARY_PATH"
}

setup_tls() {
    local node_hostname=$1
    local node_ip=$2
    
    log_step "Setting up TLS certificates..."
    
    mkdir -p "$CONFIG_DIR"
    
    if [[ -f "$CONFIG_DIR/node_exporter.crt" && -f "$CONFIG_DIR/node_exporter.key" ]]; then
        log_warn "Existing certificates found"
        read -rp "$(echo -e "${YELLOW}Regenerate certificates? (y/N): ${NC}")" choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_info "Keeping existing certificates"
            return 0
        fi
    fi
    
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -keyout "$CONFIG_DIR/node_exporter.key" \
        -out "$CONFIG_DIR/node_exporter.crt" \
        -subj "/CN=${node_hostname}" \
        -addext "subjectAltName = DNS:${node_hostname},IP:${node_ip}" \
        2>/dev/null
    
    chmod 600 "$CONFIG_DIR/node_exporter.key"
    chmod 644 "$CONFIG_DIR/node_exporter.crt"
    
    cat > "$CONFIG_DIR/web-config.yml" << 'EOF'
tls_server_config:
  cert_file: /etc/node_exporter/node_exporter.crt
  key_file: /etc/node_exporter/node_exporter.key
EOF
    
    log_info "TLS certificates generated (valid 10 years)"
}

create_service() {
    local port=$1
    
    log_step "Creating systemd service (port: ${port})..."
    
    cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
Type=simple
ExecStart=${BINARY_PATH} --web.listen-address=0.0.0.0:${port} --web.config.file=${CONFIG_DIR}/web-config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable node_exporter
    systemctl start node_exporter
    
    # Wait for startup
    sleep 2
    
    if systemctl is-active --quiet node_exporter; then
        log_info "Service started successfully"
    else
        log_error "Service failed to start!"
        journalctl -u node_exporter --no-pager -n 10
        exit 1
    fi
}

setup_firewall() {
    local prometheus_ip=$1
    local port=$2
    
    log_step "Configuring firewall..."
    
    if ! command -v ufw &>/dev/null; then
        log_warn "UFW not found, skipping firewall configuration"
        log_warn "Make sure port ${port} is accessible from ${prometheus_ip}"
        return 0
    fi
    
    # Check if rule already exists
    if ufw status | grep -q "${port}.*${prometheus_ip}"; then
        log_info "Firewall rule already exists"
    else
        ufw allow from "$prometheus_ip" to any port "$port" proto tcp comment 'Node Exporter - Prometheus' >/dev/null 2>&1
        log_info "Firewall rule added: allow ${prometheus_ip} -> port ${port}"
    fi
}

verify_install() {
    local port=$1
    
    log_step "Verifying installation..."
    
    local response
    response=$(curl -sk "https://localhost:${port}/metrics" 2>&1 | head -1)
    
    if echo "$response" | grep -q "HELP"; then
        log_info "Metrics endpoint is responding"
        return 0
    else
        log_error "Metrics endpoint not responding!"
        log_error "Response: $response"
        return 1
    fi
}

print_summary() {
    local node_ip=$1
    local port=$2
    local prometheus_ip=$3
    
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         Installation Complete!               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}Node Exporter:${NC} v${NODE_EXPORTER_VERSION}"
    echo -e "  ${GREEN}TLS:${NC}           enabled"
    echo -e "  ${GREEN}Port:${NC}          ${port}"
    echo -e "  ${GREEN}Node IP:${NC}       ${node_ip}"
    echo -e "  ${GREEN}Prometheus IP:${NC} ${prometheus_ip}"
    echo ""
    echo -e "  ${YELLOW}Add to prometheus.yml:${NC}"
    echo -e "  ${CYAN}- '${node_ip}:${port}'${NC}"
    echo ""
    echo -e "  ${YELLOW}Commands:${NC}"
    echo -e "  systemctl status node_exporter"
    echo -e "  systemctl restart node_exporter"
    echo -e "  curl -k https://localhost:${port}/metrics | head -5"
    echo ""
}

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -p, --prometheus-ip IP   IP address of Prometheus server (required)"
    echo "  -P, --port PORT          Node Exporter port (default: ${DEFAULT_PORT})"
    echo "  -n, --hostname NAME      Override hostname for certificate"
    echo "  -i, --node-ip IP         Override node IP for certificate"
    echo "  -v, --version VER        Node Exporter version (default: ${NODE_EXPORTER_VERSION})"
    echo "  -h, --help               Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --prometheus-ip 193.39.208.155"
    echo "  $0 --prometheus-ip 193.39.208.155 --port 9100"
    echo "  $0 -p 193.39.208.155 -P 9101 -n my-node"
    echo ""
}

# ============================================================
# Main
# ============================================================

main() {
    local prometheus_ip=""
    local port="$DEFAULT_PORT"
    local node_hostname=""
    local node_ip=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--prometheus-ip)
                prometheus_ip="$2"
                shift 2
                ;;
            -P|--port)
                port="$2"
                shift 2
                ;;
            -n|--hostname)
                node_hostname="$2"
                shift 2
                ;;
            -i|--node-ip)
                node_ip="$2"
                shift 2
                ;;
            -v|--version)
                NODE_EXPORTER_VERSION="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                # Support positional argument for prometheus IP
                if [[ -z "$prometheus_ip" ]]; then
                    prometheus_ip="$1"
                fi
                shift
                ;;
        esac
    done
    
    print_banner
    check_root
    
    # Get Prometheus IP
    if [[ -z "$prometheus_ip" ]]; then
        read -rp "$(echo -e "${YELLOW}Prometheus server IP: ${NC}")" prometheus_ip
    fi
    
    if [[ -z "$prometheus_ip" ]]; then
        log_error "Prometheus IP is required"
        show_usage
        exit 1
    fi
    
    # Validate IP format
    if [[ ! "$prometheus_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid IP format: $prometheus_ip"
        exit 1
    fi
    
    # Detect node IP
    if [[ -z "$node_ip" ]]; then
        log_info "Detecting public IP..."
        node_ip=$(detect_ip)
        if [[ -z "$node_ip" ]]; then
            log_error "Could not detect public IP. Use --node-ip flag"
            exit 1
        fi
        log_info "Detected IP: ${node_ip}"
    fi
    
    # Detect hostname
    if [[ -z "$node_hostname" ]]; then
        node_hostname=$(detect_hostname)
        log_info "Hostname: ${node_hostname}"
    fi
    
    # Check existing installation
    check_existing
    
    # Find free port
    port=$(find_free_port "$port")
    log_info "Using port: ${port}"
    
    # Install
    install_binary
    setup_tls "$node_hostname" "$node_ip"
    create_service "$port"
    setup_firewall "$prometheus_ip" "$port"
    
    # Verify
    if verify_install "$port"; then
        print_summary "$node_ip" "$port" "$prometheus_ip"
    else
        log_error "Installation completed but verification failed"
        log_error "Check: journalctl -u node_exporter -f"
        exit 1
    fi
}

main "$@"
