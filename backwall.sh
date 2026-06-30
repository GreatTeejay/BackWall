#!/usr/bin/env bash
#
#  ____             _    __        __      _ _
# | __ )  __ _  ___| | _ \ \      / /_ _  | | |
# |  _ \ / _` |/ __| |/ /  \ \ /\ / / _` | | | |
# | |_) | (_| | (__|   <    \ V  V / (_| | | | |
# |____/ \__,_|\___|_|\_\    \_/\_/ \__,_| |_|_|
#
#  BackWall — Teejay Edition
#  Lightning-fast reverse tunneling manager
#  Repo: https://github.com/GreatTeejay/BackWall
#
#  A clean, readable rewrite of a Backhaul-based tunnel manager.
#  Licensed under the MIT License.
#
set -o pipefail

# ────────────────────────────────────────────────────────────────
#  Global configuration (override via environment variables)
# ────────────────────────────────────────────────────────────────
SCRIPT_VERSION="1.0.0"
CORE_VERSION="1.0.0"
BRAND="BackWall"
BRAND_EDITION="Teejay Edition"

# GitHub repository used for core releases and self-updates
GH_OWNER="${BACKWALL_GH_OWNER:-GreatTeejay}"
GH_REPO="${BACKWALL_GH_REPO:-BackWall}"
GH_BASE="https://github.com/${GH_OWNER}/${GH_REPO}"
GH_RAW="https://raw.githubusercontent.com/${GH_OWNER}/${GH_REPO}/main"
# Binary is distributed via GitHub Releases (tag = "core")
CORE_RELEASE_TAG="${BACKWALL_CORE_TAG:-core}"

# Filesystem layout
service_dir="/etc/systemd/system"
config_dir="${BACKWALL_DIR:-/root/backwall-core}"
CERT_DIR="${config_dir}/cert_files"
CERT_FILE="$CERT_DIR/cert.crt"
KEY_FILE="$CERT_DIR/cert.key"
CORE_BIN="${config_dir}/backwall_core"
SERVICE_PREFIX="backwall"
INSTALL_PATH="/usr/local/bin/backwall"

mkdir -p "$CERT_DIR"

# Must run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    sleep 1
    exit 1
fi

# ────────────────────────────────────────────────────────────────
#  UI helpers
# ────────────────────────────────────────────────────────────────
colorize() {
    local color="$1" text="$2" style="${3:-normal}"
    local black="\033[30m" red="\033[31m" green="\033[32m" yellow="\033[33m"
    local blue="\033[34m" magenta="\033[35m" cyan="\033[36m" white="\033[37m"
    local reset="\033[0m" normal="\033[0m" bold="\033[1m" underline="\033[4m"
    local color_code style_code
    case "$color" in
        black) color_code=$black ;;   red) color_code=$red ;;
        green) color_code=$green ;;   yellow) color_code=$yellow ;;
        blue) color_code=$blue ;;     magenta) color_code=$magenta ;;
        cyan) color_code=$cyan ;;     white) color_code=$white ;;
        *) color_code=$reset ;;
    esac
    case "$style" in
        bold) style_code=$bold ;;
        underline) style_code=$underline ;;
        *) style_code=$normal ;;
    esac
    echo -e "${style_code}${color_code}${text}${reset}"
}

press_key() {
    read -r -p "Press any key to continue..." _
}

prompt_with_default() {
    local prompt="$1" default="$2" var_name="$3" input
    echo -ne "[-] $prompt (default: $default): "
    read -r input
    printf -v "$var_name" '%s' "${input:-$default}"
}

prompt_boolean() {
    local prompt="$1" default="$2" var_name="$3"
    while true; do
        prompt_with_default "$prompt [true/false]" "$default" "$var_name"
        local value="${!var_name}"
        [[ "$value" == "true" || "$value" == "false" ]] && break
        colorize red "Invalid input. Please enter 'true' or 'false'."
    done
}

# ────────────────────────────────────────────────────────────────
#  Validation helpers
# ────────────────────────────────────────────────────────────────
validate_cidr() {
    local cidr="$1"
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
    local ip mask a b c d
    IFS='/' read -r ip mask <<< "$cidr"
    IFS='.' read -r a b c d <<< "$ip"
    (( a<=255 && b<=255 && c<=255 && d<=255 )) || return 1
    (( mask >= 1 && mask <= 32 )) || return 1
    local ip_int=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    local mask_int
    if (( mask == 32 )); then
        mask_int=0xFFFFFFFF
    else
        mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
    fi
    local net_int=$(( ip_int & mask_int ))
    local broadcast_int=$(( net_int | (~mask_int & 0xFFFFFFFF) ))
    (( ip_int == net_int )) && return 1
    (( ip_int == broadcast_int )) && return 1
    return 0
}

# Return 0 if $1 is exactly equal to any of the remaining arguments
in_list() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$needle" == "$item" ]] && return 0
    done
    return 1
}

VALID_ALGORITHMS=("aes-256-gcm" "chacha20-poly1305" "aes-128-gcm")
is_valid_algorithm() {
    in_list "$1" "${VALID_ALGORITHMS[@]}"
}

# ────────────────────────────────────────────────────────────────
#  Dependency management
# ────────────────────────────────────────────────────────────────
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then echo "apt"; return; fi
    if command -v dnf &>/dev/null; then echo "dnf"; return; fi
    if command -v yum &>/dev/null; then echo "yum"; return; fi
    if command -v pacman &>/dev/null; then echo "pacman"; return; fi
    echo "unknown"
}

install_package() {
    local pkg="$1" pm
    pm=$(detect_pkg_manager)
    colorize yellow "Installing $pkg..."
    case "$pm" in
        apt)    apt-get update -qq && apt-get install -y "$pkg" ;;
        dnf)    dnf install -y "$pkg" ;;
        yum)    yum install -y "$pkg" ;;
        pacman) pacman -Sy --noconfirm "$pkg" ;;
        *)
            colorize red "Unsupported package manager. Please install '$pkg' manually."
            return 1
            ;;
    esac
}

ensure_dependencies() {
    local deps=(jq curl tar openssl)
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            install_package "$dep" || { press_key; exit 1; }
        fi
    done
}

# ────────────────────────────────────────────────────────────────
#  Core download & install (via GitHub Releases)
# ────────────────────────────────────────────────────────────────
download_and_extract_core() {
    if [[ "$1" == "menu" ]]; then
        rm -rf "$CORE_BIN" >/dev/null 2>&1
        colorize cyan "Restart all services after updating to the new core." bold
        sleep 2
    fi

    [[ -f "$CORE_BIN" ]] && return 0

    local arch asset
    arch=$(uname -m)
    case "$arch" in
        x86_64)        asset="backwall_core_linux_amd64.tar.gz" ;;
        arm64|aarch64) asset="backwall_core_linux_arm64.tar.gz" ;;
        *)
            colorize red "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    # GitHub Releases download URL (+ optional override mirror)
    local primary="${GH_BASE}/releases/download/${CORE_RELEASE_TAG}/${asset}"
    local fallback="${BACKWALL_MIRROR_URL:-$primary}"

    local tmp
    tmp=$(mktemp -d)
    colorize cyan "Downloading ${BRAND} core (${arch})..."

    if ! curl -fsSL --max-time 30 -o "$tmp/core.tar.gz" "$primary"; then
        colorize yellow "Primary download failed. Trying fallback mirror..."
        if ! curl -fsSL --max-time 60 -o "$tmp/core.tar.gz" "$fallback"; then
            colorize red "Download failed. Check your connection or set BACKWALL_MIRROR_URL."
            rm -rf "$tmp"
            exit 1
        fi
    fi

    mkdir -p "$config_dir"
    if ! tar -xzf "$tmp/core.tar.gz" -C "$config_dir"; then
        colorize red "Failed to extract the core archive."
        rm -rf "$tmp"
        exit 1
    fi
    rm -rf "$tmp"

    # The archive may ship the binary under its upstream name; normalise it.
    if [[ ! -f "$CORE_BIN" ]]; then
        local found
        found=$(find "$config_dir" -maxdepth 1 -type f \
                \( -name 'backwall_core' -o -name 'backhaul*' -o -name '*_core' \) \
                ! -name '*.toml' | head -n1)
        [[ -n "$found" && "$found" != "$CORE_BIN" ]] && mv -f "$found" "$CORE_BIN"
    fi

    if [[ ! -f "$CORE_BIN" ]]; then
        colorize red "Core binary not found after extraction."
        exit 1
    fi

    chmod u+x "$CORE_BIN"
    colorize green "${BRAND} core installed successfully." bold
}

# ────────────────────────────────────────────────────────────────
#  Configuration prompts
# ────────────────────────────────────────────────────────────────
declare -A CONFIG
reset_config() { CONFIG=(); }

prompt_connection_section() {
    local mode="$1"
    colorize blue "━━━ Connection Configuration ━━━" bold
    if [[ "$mode" == "server" ]]; then
        prompt_with_default "Bind Address" ":8443" CONFIG[bind_addr]
        if [[ -n "${CONFIG[bind_addr]}" && "${CONFIG[bind_addr]}" != *:* ]]; then
            CONFIG[bind_addr]=":${CONFIG[bind_addr]}"
        fi
    else
        while true; do
            echo -ne "[*] IRAN Server Address [IP:Port] or [Domain:Port]: "
            read -r "CONFIG[remote_addr]"
            if [[ -z "${CONFIG[remote_addr]}" ]]; then
                colorize red "Server address cannot be empty."
                continue
            fi
            if [[ "${CONFIG[remote_addr]}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ || \
                  "${CONFIG[remote_addr]}" =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]]; then
                break
            fi
            colorize red "Invalid format. Use IP:Port or Domain:Port."
        done
        case "${CONFIG[transport_type]}" in
            ws|wss|wsmux|wssmux|xwsmux)
                echo -ne "[-] Edge IP/Domain (optional, press Enter to skip): "
                read -r "CONFIG[edge_ip]"
                ;;
        esac
        CONFIG[dial_timeout]="10"
        CONFIG[retry_interval]="3"
    fi
    echo ""
}

prompt_security_section() {
    local is_ipx="$1"
    colorize blue "━━━ Security Configuration ━━━" bold
    if [[ "$is_ipx" == "true" ]]; then
        prompt_boolean "Enable Encryption" "true" CONFIG[enable_encryption]
        if [[ "${CONFIG[enable_encryption]}" == "true" ]]; then
            echo
            while true; do
                colorize magenta "Available algorithms: ${VALID_ALGORITHMS[*]}"
                prompt_with_default "Algorithm" "aes-256-gcm" CONFIG[algorithm]
                is_valid_algorithm "${CONFIG[algorithm]}" && break
                colorize red "Invalid algorithm. Please choose one from the list."
                echo
            done
            prompt_with_default "PSK (32-char base64)" "$(openssl rand -base64 32)" CONFIG[psk]
            prompt_with_default "KDF Iterations" "100000" CONFIG[kdf_iterations]
        fi
    else
        prompt_with_default "Security Token" "your_token" CONFIG[token]
        CONFIG[enable_encryption]="false"
    fi
    echo ""
}

prompt_transport_section() {
    local mode="$1" is_ipx="false"
    colorize blue "━━━ Transport Configuration ━━━" bold
    local valid_transports=(tcp tcpmux xtcpmux ws wss wsmux wssmux xwsmux anytls tun)
    echo "Available transports:"
    printf '  • %s\n' "${valid_transports[@]}"
    while true; do
        echo -ne "Select transport: "
        read -r "CONFIG[transport_type]"
        in_list "${CONFIG[transport_type]}" "${valid_transports[@]}" && break
        colorize red "Invalid transport."
    done

    if [[ "${CONFIG[transport_type]}" == "tun" ]]; then
        echo
        local encapsulations=(tcp ipx)
        echo "Available encapsulations:"
        printf '  • %s\n' "${encapsulations[@]}"
        while true; do
            echo -ne "Select encapsulation: "
            read -r "CONFIG[tun_encapsulation]"
            in_list "${CONFIG[tun_encapsulation]}" "${encapsulations[@]}" && break
            colorize red "Invalid encapsulation."
        done
    fi
    echo
    [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx="true"

    if [[ "$is_ipx" != "true" ]]; then
        prompt_boolean "Enable TCP_NODELAY" "true" CONFIG[nodelay]
    fi

    if [[ "$mode" == "server" ]]; then
        if [[ "${CONFIG[transport_type]}" == "tcp" ]]; then
            prompt_boolean "Accept UDP over TCP" "false" CONFIG[accept_udp]
        fi
        if [[ ! "${CONFIG[transport_type]}" =~ ^(tun|ws)$ ]] && [[ "$is_ipx" != "true" ]]; then
            prompt_boolean "Enable Proxy Protocol" "false" CONFIG[proxy_protocol]
        fi
    else
        if [[ "${CONFIG[transport_type]}" != "tun" ]]; then
            prompt_with_default "Connection Pool" "8" CONFIG[connection_pool]
        fi
    fi

    CONFIG[heartbeat_interval]="10"
    CONFIG[heartbeat_timeout]="25"
    [[ "$is_ipx" != "true" ]] && CONFIG[keepalive_period]="40"
    echo ""
}

prompt_mux_section() {
    local transport="$1"
    [[ "$transport" =~ mux$ ]] || return
    colorize blue "━━━ Mux Configuration ━━━" bold
    prompt_with_default "Mux Version [1 or 2]" "2" CONFIG[mux_version]
    prompt_with_default "Mux Concurrency" "8" CONFIG[mux_concurrency]
    CONFIG[mux_framesize]="32768"
    CONFIG[mux_recievebuffer]="4194304"
    CONFIG[mux_streambuffer]="2097152"
    echo ""
}

prompt_tun_section() {
    local transport="$1" mode="$2" is_ipx="$3"
    [[ "$transport" != "tun" ]] && return
    colorize blue "━━━ TUN Configuration ━━━" bold
    prompt_with_default "TUN Device Name" "backwall" CONFIG[tun_name]
    local default_local default_remote
    if [[ "$mode" == "server" ]]; then
        default_local="10.10.10.1/24"; default_remote="10.10.10.2/24"
    else
        default_local="10.10.10.2/24"; default_remote="10.10.10.1/24"
    fi
    while true; do
        prompt_with_default "TUN Local Address (CIDR)" "$default_local" CONFIG[tun_local_addr]
        validate_cidr "${CONFIG[tun_local_addr]}" && break
        colorize red "Invalid CIDR (avoid network/broadcast addresses)."
    done
    while true; do
        prompt_with_default "TUN Remote Address (CIDR)" "$default_remote" CONFIG[tun_remote_addr]
        validate_cidr "${CONFIG[tun_remote_addr]}" && break
        colorize red "Invalid CIDR format."
    done
    prompt_with_default "Health Port" "1234" CONFIG[tun_health_port]
    if [[ "$is_ipx" == "true" ]]; then
        prompt_with_default "MTU" "1320" CONFIG[tun_mtu]
    else
        prompt_with_default "MTU" "1500" CONFIG[tun_mtu]
    fi
    echo ""
}

prompt_tls_section() {
    local mode="$1" transport="$2"
    [[ "$transport" =~ ^(anytls|wss|wssmux)$ ]] || return
    colorize blue "━━━ TLS Configuration ━━━" bold
    if [[ "$transport" == "anytls" ]]; then
        prompt_with_default "SNI" "www.digikala.com" CONFIG[tls_sni]
    fi
    if [[ "$mode" == "client" ]]; then
        echo
        return
    fi
    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        colorize red "[*] TLS cert/key missing — generating self-signed ECDSA cert..."
        openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -x509 -days 365 -sha256 -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/CN=${GH_REPO,,}.local" >/dev/null 2>&1
        colorize green "[*] Generated $CERT_FILE and $KEY_FILE"
        echo
    fi
    prompt_with_default "TLS Certificate Path" "$CERT_FILE" CONFIG[tls_cert]
    prompt_with_default "TLS Key Path" "$KEY_FILE" CONFIG[tls_key]
    echo ""
}

prompt_tuning_section() {
    local is_ipx="$1" is_tun="$2"
    colorize blue "━━━ Tuning Configuration ━━━" bold
    prompt_boolean "Enable Auto Tuning" "true" CONFIG[auto_tuning]
    echo
    colorize magenta "Profiles: balanced, fast, latency, resource"
    prompt_with_default "Kernel Tuning Profile" "balanced" CONFIG[tuning_profile]
    prompt_with_default "Workers (0 = auto)" "0" CONFIG[workers]
    if [[ "$is_tun" != "true" ]]; then
        prompt_with_default "Channel Size" "4096" CONFIG[channel_size]
    else
        CONFIG[channel_size]="10_000"
    fi
    if [[ "$is_ipx" == "true" ]]; then
        prompt_with_default "Batch Size" "2048" CONFIG[batch_size]
        prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
    else
        prompt_with_default "TCP MSS (0 = auto)" "0" CONFIG[tcp_mss]
        prompt_with_default "SO_RCVBUF (0 = auto)" "0" CONFIG[so_rcvbuf]
        prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
    fi
    if [[ "$is_tun" != "true" && "$is_ipx" != "true" ]]; then
        echo
        colorize magenta "Buffer Profiles: extreme_low_cpu, ultra_low_cpu, low_cpu, balanced, low_memory"
        prompt_with_default "Buffer Profile" "balanced" CONFIG[buffer_profile]
        prompt_with_default "Read Timeout" "120" CONFIG[read_timeout]
    fi
    echo ""
}

prompt_logging_section() {
    colorize blue "━━━ Logging Configuration ━━━" bold
    colorize magenta "Levels: panic, fatal, error, warn, info, debug, trace"
    prompt_with_default "Log Level" "info" CONFIG[log_level]
    echo ""
}

prompt_accept_udp_section() {
    [[ "$1" != "true" ]] && return
    CONFIG[ring_size]="64"
    CONFIG[frame_size]="2048"
    CONFIG[peer_idle_timeout_s]="120"
    CONFIG[write_timeout_ms]="3"
}

prompt_ports_section() {
    local mode="$1" is_tun="$2"
    [[ "$mode" != "server" ]] && return
    if [[ "$is_tun" != "true" ]]; then
        colorize blue "━━━ Port Mapping Configuration ━━━" bold
        colorize green "Supported formats:"
        echo "  1. 443           - Listen on 443, forward to 443"
        echo "  2. 443=5000      - Listen on 443, forward to 5000"
        echo "  3. 443-600       - Listen on range 443-600"
        echo "  4. 443-600:5201  - Range forwarding to 5201"
        echo ""
        echo -ne "Enter port mappings (comma-separated): "
        read -r "CONFIG[ports_mapping]"
        echo ""
    else
        colorize blue "━━━ Port Mapping (TUN helper) ━━━" bold
        colorize magenta "Forwarder: 'backwall' for TCP only, or 'iptables' for TCP + UDP"
        prompt_with_default "Forwarder (backwall/iptables)" "backwall" CONFIG[forwarder]
        echo ""
        colorize green "Supported formats:"
        echo "  1. 443           - Listen on 443, forward to 443"
        echo "  2. 443=5000      - Listen on 443, forward to 5000"
        echo ""
        echo -ne "Enter port mappings (comma-separated): "
        read -r "CONFIG[ports_mapping]"
        echo ""
    fi
}

prompt_ipx_section() {
    local is_ipx="$1" mode="$2"
    [[ "$is_ipx" != "true" ]] && return
    colorize blue "━━━ IPX Configuration ━━━" bold
    CONFIG[ipx_mode]="$mode"
    local AVAILABLE_PROFILES=("icmp" "ipip" "udp" "tcp" "gre" "bip")
    colorize magenta "Available profiles: ${AVAILABLE_PROFILES[*]}"
    while true; do
        prompt_with_default "Profile" "tcp" CONFIG[ipx_profile]
        CONFIG[ipx_profile]="${CONFIG[ipx_profile],,}"
        for profile in "${AVAILABLE_PROFILES[@]}"; do
            [[ "${CONFIG[ipx_profile]}" == "$profile" ]] && break 2
        done
        colorize red "Invalid profile: ${CONFIG[ipx_profile]}"
        colorize yellow "Please choose one of: ${AVAILABLE_PROFILES[*]}"
    done
    prompt_with_default "Listen IP" "$SERVER_IP" CONFIG[ipx_listen_ip]
    while :; do
        prompt_with_default "Destination IP" "" CONFIG[ipx_dst_ip]
        [[ -n "${CONFIG[ipx_dst_ip]}" ]] && break
        colorize red "Destination IP cannot be empty."
    done
    local interface
    interface=$(ip route show default | awk '{print $5}' | head -n1)
    prompt_with_default "Network Interface" "$interface" CONFIG[ipx_interface]
    if [[ "${CONFIG[ipx_profile]}" == "icmp" ]]; then
        prompt_with_default "ICMP Type" "0" CONFIG[ipx_icmp_type]
        prompt_with_default "ICMP Code" "0" CONFIG[ipx_icmp_code]
    fi
    echo ""
}

# ────────────────────────────────────────────────────────────────
#  TOML generation
# ────────────────────────────────────────────────────────────────
generate_toml_config() {
    local mode="$1" output_file="$2" is_tun="$3" is_ipx="$4"
    {
        if [[ "$mode" == "server" && "$is_ipx" == "false" ]]; then
            echo "[listener]"
            echo "bind_addr = \"${CONFIG[bind_addr]}\""
            echo ""
        elif [[ "$is_ipx" == "false" ]]; then
            echo "[dialer]"
            echo "remote_addr = \"${CONFIG[remote_addr]}\""
            [[ -n "${CONFIG[edge_ip]}" ]] && echo "edge_ip = \"${CONFIG[edge_ip]}\""
            echo "dial_timeout = ${CONFIG[dial_timeout]}"
            echo "retry_interval = ${CONFIG[retry_interval]}"
            echo ""
        fi

        echo "[transport]"
        echo "type = \"${CONFIG[transport_type]}\""
        [[ -n "${CONFIG[nodelay]}" ]] && echo "nodelay = ${CONFIG[nodelay]}"
        [[ -n "${CONFIG[keepalive_period]}" ]] && echo "keepalive_period = ${CONFIG[keepalive_period]}"
        if [[ "$mode" == "server" ]]; then
            [[ -n "${CONFIG[accept_udp]}" ]] && echo "accept_udp = ${CONFIG[accept_udp]}"
            [[ -n "${CONFIG[proxy_protocol]}" ]] && echo "proxy_protocol = ${CONFIG[proxy_protocol]}"
        else
            [[ -n "${CONFIG[connection_pool]}" && "${CONFIG[connection_pool]}" != "0" ]] && \
                echo "connection_pool = ${CONFIG[connection_pool]}"
        fi
        [[ -n "${CONFIG[heartbeat_interval]}" ]] && echo "heartbeat_interval = ${CONFIG[heartbeat_interval]}"
        [[ -n "${CONFIG[heartbeat_timeout]}" ]] && echo "heartbeat_timeout = ${CONFIG[heartbeat_timeout]}"
        echo ""

        if [[ "$is_tun" == "true" ]]; then
            echo "[tun]"
            echo "encapsulation = \"${CONFIG[tun_encapsulation]}\""
            echo "name = \"${CONFIG[tun_name]}\""
            echo "local_addr = \"${CONFIG[tun_local_addr]}\""
            echo "remote_addr = \"${CONFIG[tun_remote_addr]}\""
            echo "health_port = ${CONFIG[tun_health_port]}"
            echo "mtu = ${CONFIG[tun_mtu]}"
            echo ""
        fi

        if [[ "$is_ipx" == "true" ]]; then
            echo "[ipx]"
            echo "mode = \"${CONFIG[ipx_mode]}\""
            echo "profile = \"${CONFIG[ipx_profile]}\""
            echo "listen_ip = \"${CONFIG[ipx_listen_ip]}\""
            echo "dst_ip = \"${CONFIG[ipx_dst_ip]}\""
            echo "interface = \"${CONFIG[ipx_interface]}\""
            [[ -n "${CONFIG[ipx_icmp_type]}" ]] && echo "icmp_type = ${CONFIG[ipx_icmp_type]}"
            [[ -n "${CONFIG[ipx_icmp_code]}" ]] && echo "icmp_code = ${CONFIG[ipx_icmp_code]}"
            echo ""
        fi

        if [[ "${CONFIG[transport_type]}" =~ mux$ ]]; then
            echo "[mux]"
            echo "mux_version = ${CONFIG[mux_version]}"
            echo "mux_framesize = ${CONFIG[mux_framesize]}"
            echo "mux_recievebuffer = ${CONFIG[mux_recievebuffer]}"
            echo "mux_streambuffer = ${CONFIG[mux_streambuffer]}"
            [[ -n "${CONFIG[mux_concurrency]}" ]] && echo "mux_concurrency = ${CONFIG[mux_concurrency]}"
            echo ""
        fi

        echo "[security]"
        if [[ "$is_ipx" == "true" ]]; then
            echo "enable_encryption = ${CONFIG[enable_encryption]}"
            if [[ "${CONFIG[enable_encryption]}" == "true" ]]; then
                echo "algorithm = \"${CONFIG[algorithm]}\""
                echo "psk = \"${CONFIG[psk]}\""
                echo "kdf_iterations = ${CONFIG[kdf_iterations]}"
            fi
        else
            echo "token = \"${CONFIG[token]}\""
        fi
        echo ""

        if [[ -n "${CONFIG[tls_sni]}" || -n "${CONFIG[tls_cert]}" ]]; then
            echo "[tls]"
            [[ -n "${CONFIG[tls_sni]}" ]]  && echo "sni = \"${CONFIG[tls_sni]}\""
            [[ -n "${CONFIG[tls_cert]}" ]] && echo "tls_cert = \"${CONFIG[tls_cert]}\""
            [[ -n "${CONFIG[tls_key]}" ]]  && echo "tls_key = \"${CONFIG[tls_key]}\""
            echo ""
        fi

        echo "[tuning]"
        [[ -n "${CONFIG[auto_tuning]}" ]]    && echo "auto_tuning = ${CONFIG[auto_tuning]}"
        [[ -n "${CONFIG[tuning_profile]}" ]] && echo "tuning_profile = \"${CONFIG[tuning_profile]}\""
        [[ -n "${CONFIG[workers]}" ]]        && echo "workers = ${CONFIG[workers]}"
        [[ -n "${CONFIG[channel_size]}" ]]   && echo "channel_size = ${CONFIG[channel_size]}"
        [[ -n "${CONFIG[tcp_mss]}" ]]        && echo "tcp_mss = ${CONFIG[tcp_mss]}"
        [[ -n "${CONFIG[so_rcvbuf]}" ]]      && echo "so_rcvbuf = ${CONFIG[so_rcvbuf]}"
        [[ -n "${CONFIG[so_sndbuf]}" ]]      && echo "so_sndbuf = ${CONFIG[so_sndbuf]}"
        [[ -n "${CONFIG[buffer_profile]}" ]] && echo "buffer_profile = \"${CONFIG[buffer_profile]}\""
        [[ -n "${CONFIG[batch_size]}" ]]     && echo "batch_size = ${CONFIG[batch_size]}"
        [[ -n "${CONFIG[read_timeout]}" ]]   && echo "read_timeout = ${CONFIG[read_timeout]}"
        echo ""

        if [[ "${CONFIG[accept_udp]}" == "true" ]]; then
            echo "[accept_udp]"
            echo "ring_size = ${CONFIG[ring_size]}"
            echo "frame_size = ${CONFIG[frame_size]}"
            echo "peer_idle_timeout_s = ${CONFIG[peer_idle_timeout_s]}"
            echo "write_timeout_ms = ${CONFIG[write_timeout_ms]}"
            echo ""
        fi

        echo "[logging]"
        echo "log_level = \"${CONFIG[log_level]}\""
        echo ""

        if [[ "$mode" == "server" ]]; then
            echo "[ports]"
            [[ -n "${CONFIG[forwarder]}" ]] && echo "forwarder = \"${CONFIG[forwarder]}\""
            echo "mapping = ["
            IFS=',' read -r -a ports <<< "${CONFIG[ports_mapping]}"
            for port in "${ports[@]}"; do
                [[ -n "$port" ]] && echo "    \"${port// /}\","
            done
            echo "]"
        fi
    } > "$output_file"
}

# ────────────────────────────────────────────────────────────────
#  systemd service management
# ────────────────────────────────────────────────────────────────
write_service_file() {
    local service_file="$1" desc="$2" config_file="$3"
    cat > "$service_file" <<EOF
[Unit]
Description=${BRAND} ${desc}
After=network.target

[Service]
Type=simple
User=root
ExecStart=${CORE_BIN} -c ${config_file}
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

create_systemd_service() {
    local type="$1" port="$2" config_file="$3"
    local service_file="${service_dir}/${SERVICE_PREFIX}-${type}${port}.service"
    local desc_type
    desc_type="$(tr '[:lower:]' '[:upper:]' <<< "${type:0:1}")${type:1}"
    write_service_file "$service_file" "$desc_type Port $port" "$config_file"
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_PREFIX}-${type}${port}.service" >/dev/null 2>&1
    colorize green "✔ Service ${SERVICE_PREFIX}-${type}${port} created and started" bold
}

configure_server() {
    local mode="$1" mode_name
    [[ "$mode" == "server" ]] && mode_name="IRAN (Server)" || mode_name="KHAREJ (Client)"
    clear
    colorize cyan "Configuring $mode_name" bold
    echo ""
    reset_config
    prompt_transport_section "$mode"

    local is_tun="false" is_ipx="false"
    [[ "${CONFIG[transport_type]}" == "tun" ]] && is_tun="true"
    [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx="true"

    prompt_tun_section "${CONFIG[transport_type]}" "$mode" "$is_ipx"
    prompt_ipx_section "$is_ipx" "$mode"
    [[ "$is_ipx" != "true" ]] && prompt_connection_section "$mode"
    prompt_security_section "$is_ipx"
    prompt_accept_udp_section "${CONFIG[accept_udp]}"
    prompt_mux_section "${CONFIG[transport_type]}"
    prompt_tls_section "$mode" "${CONFIG[transport_type]}"
    prompt_tuning_section "$is_ipx" "$is_tun"
    prompt_logging_section
    prompt_ports_section "$mode" "$is_tun"

    local tunnel_port
    if [[ "$mode" == "server" ]]; then
        tunnel_port=$(grep -oP ':\K[0-9]+$' <<< "${CONFIG[bind_addr]}")
    else
        tunnel_port=$(grep -oP ':\K[0-9]+$' <<< "${CONFIG[remote_addr]}")
    fi
    [[ -z "$tunnel_port" ]] && tunnel_port="${CONFIG[tun_health_port]}"

    local config_file service_type
    if [[ "$mode" == "server" ]]; then
        config_file="${config_dir}/iran${tunnel_port}.toml"; service_type="iran"
    else
        config_file="${config_dir}/kharej${tunnel_port}.toml"; service_type="kharej"
    fi

    generate_toml_config "$mode" "$config_file" "$is_tun" "$is_ipx"
    create_systemd_service "$service_type" "$tunnel_port" "$config_file"
    echo ""
    colorize green "✔ Configuration completed successfully!" bold
    echo ""
    press_key
}

# ────────────────────────────────────────────────────────────────
#  Server info / display
# ────────────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')
_IPINFO=$(curl -sS --max-time 2 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null)
SERVER_COUNTRY=$(jq -r '.country // "Unknown"' <<< "$_IPINFO" 2>/dev/null)
SERVER_ISP=$(jq -r '.isp // "Unknown"' <<< "$_IPINFO" 2>/dev/null)

display_logo() {
    echo -e "\033[1;36m"
    cat << "EOF"
   ╭───────────────────────────────────────────────╮
   │   ____             _    __        __       _ _  │
   │  | __ )  __ _  ___| | _ \ \      / /__ _  | | | │
   │  |  _ \ / _` |/ __| |/ /  \ \ /\ / / _` | | | | │
   │  | |_) | (_| | (__|   <    \ V  V / (_| | | | | │
   │  |____/ \__,_|\___|_|\_\    \_/\_/ \__,_| |_|_| │
   ╰───────────────────────────────────────────────╯
EOF
    echo -e "\033[0m"
    echo -e "        \033[2;37mLightning-fast reverse tunneling\033[0m"
    echo -e "                \033[1;35m• ${BRAND_EDITION} •\033[0m"
}

# Print one aligned info row:  label (cyan, padded) : value
_info_row() {
    local label="$1" value="$2" value_color="${3:-\033[0;37m}"
    printf "   \033[1;36m%-14s\033[0m ${value_color}%s\033[0m\n" "$label" "$value"
}

_divider() {
    echo -e "   \033[0;90m─────────────────────────────────────────────\033[0m"
}

display_server_info() {
    _divider
    _info_row "Script ver." "$SCRIPT_VERSION"   "\033[1;33m"
    _info_row "Core ver."   "$CORE_VERSION"     "\033[1;33m"
    _divider
    _info_row "IP Address"  "$SERVER_IP"
    _info_row "Location"    "$SERVER_COUNTRY"
    _info_row "Datacenter"  "$SERVER_ISP"
}

display_core_status() {
    if [[ -f "$CORE_BIN" ]]; then
        _info_row "Core status" "● Installed" "\033[1;32m"
    else
        _info_row "Core status" "● Not installed" "\033[1;31m"
    fi
    _divider
}

# ────────────────────────────────────────────────────────────────
#  Self-healing: recreate missing service files
# ────────────────────────────────────────────────────────────────
check_config_backup() {
    local missing_services=() config fname location tunnel_port service_file
    for config in "${config_dir}"/iran*.toml "${config_dir}"/kharej*.toml; do
        [ -e "$config" ] || continue
        fname=$(basename "$config")
        if [[ "$fname" =~ ^(iran|kharej)([0-9]+)\.toml$ ]]; then
            location="${BASH_REMATCH[1]}"
            tunnel_port="${BASH_REMATCH[2]}"
            service_file="${service_dir}/${SERVICE_PREFIX}-${location}${tunnel_port}.service"
            [[ ! -f "$service_file" ]] && missing_services+=("$service_file:$location:$tunnel_port")
        fi
    done
    [[ ${#missing_services[@]} -eq 0 ]] && return 0

    echo
    colorize red "Missing service files:" bold
    local entry
    for entry in "${missing_services[@]}"; do
        echo "- ${entry%%:*}"
    done
    echo
    read -r -p "Create the missing service files? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for entry in "${missing_services[@]}"; do
            service_file="${entry%%:*}"
            location="${entry#*:}"; location="${location%%:*}"
            tunnel_port="${entry##*:}"
            local config_file="${config_dir}/${location}${tunnel_port}.toml"
            local desc_loc
            desc_loc="$(tr '[:lower:]' '[:upper:]' <<< "${location:0:1}")${location:1}"
            write_service_file "$service_file" "$desc_loc Port $tunnel_port" "$config_file"
            systemctl daemon-reload
            systemctl enable --now "$(basename "$service_file")" >/dev/null 2>&1
            echo "Created and started $(basename "$service_file")"
        done
    fi
    sleep 2
}

# ────────────────────────────────────────────────────────────────
#  Tunnel status / management
# ────────────────────────────────────────────────────────────────
check_tunnel_status() {
    if ! ls "$config_dir"/*.toml >/dev/null 2>&1; then
        colorize red "No config files found." bold
        press_key
        return 1
    fi
    clear
    colorize yellow "Checking all service statuses..." bold
    echo
    local config_path config_name service_name port
    for config_path in "$config_dir"/{iran,kharej}*.toml; do
        [ -f "$config_path" ] || continue
        config_name=$(basename "${config_path%.toml}")
        service_name="${SERVICE_PREFIX}-${config_name}.service"
        if [[ "$config_name" =~ ^(iran|kharej)([0-9]+)$ ]]; then
            local loc_label="${BASH_REMATCH[1]^}"
            port="${BASH_REMATCH[2]}"
            if systemctl is-active --quiet "$service_name"; then
                colorize green "$loc_label service (port $port) is running"
            else
                colorize red "$loc_label service (port $port) is not running"
            fi
        fi
    done
    echo
    press_key
}

tunnel_management() {
    if ! ls "$config_dir"/*.toml >/dev/null 2>&1; then
        colorize red "No config files found." bold
        press_key
        return 1
    fi
    clear
    colorize cyan "Existing services:" bold
    echo
    local index=1 config_path config_name port
    declare -a configs
    for config_path in "$config_dir"/{iran,kharej}*.toml; do
        [ -f "$config_path" ] || continue
        config_name=$(basename "$config_path")
        if [[ "$config_name" =~ ^(iran|kharej)([0-9]+)\.toml$ ]]; then
            local loc_label="${BASH_REMATCH[1]^}"
            port="${BASH_REMATCH[2]}"
            configs+=("$config_path")
            echo -e "\033[35m${index}\033[0m) \033[32m${loc_label}\033[0m (port: \033[33m$port\033[0m)"
            ((index++))
        fi
    done
    echo
    local choice
    echo -ne "Enter your choice (0 to return): "
    read -r choice
    [[ "$choice" == "0" ]] && return
    while ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#configs[@]} )); do
        colorize red "Invalid choice."
        echo -ne "Enter your choice (0 to return): "
        read -r choice
        [[ "$choice" == "0" ]] && return
    done

    local selected_config="${configs[$((choice - 1))]}"
    config_name=$(basename "${selected_config%.toml}")
    local service_name="${SERVICE_PREFIX}-${config_name}.service"
    clear
    colorize cyan "Manage $config_name:" bold
    echo
    colorize red    "1) Remove this tunnel"
    colorize yellow "2) Restart this tunnel"
    echo "3) View service logs"
    echo "4) View service status"
    echo
    read -r -p "Enter your choice (0 to return): " choice
    case "$choice" in
        1) destroy_tunnel "$selected_config" ;;
        2) restart_service "$service_name" ;;
        3) view_service_logs "$service_name" ;;
        4) view_service_status "$service_name" ;;
        0) return ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}

destroy_tunnel() {
    local config_path="$1"
    local config_name; config_name=$(basename "${config_path%.toml}")
    local service_name="${SERVICE_PREFIX}-${config_name}.service"
    local service_path="$service_dir/$service_name"
    [ -f "$config_path" ] && rm -f "$config_path"
    if [[ -f "$service_path" ]]; then
        systemctl is-active --quiet "$service_name" && \
            systemctl disable --now "$service_name" >/dev/null 2>&1
        rm -f "$service_path"
    fi
    systemctl daemon-reload
    echo
    colorize green "Tunnel destroyed successfully!" bold
    echo
    press_key
}

restart_service() {
    echo
    colorize yellow "Restarting $1" bold
    if systemctl list-unit-files | grep -q "$1"; then
        systemctl restart "$1"
        colorize green "Service restarted successfully" bold
    else
        colorize red "Service not found"
    fi
    echo
    press_key
}

view_service_logs() {
    clear
    journalctl -eu "$1" -f -o cat
}

view_service_status() {
    clear
    systemctl status "$1"
    press_key
}

remove_core() {
    if find "$config_dir" -type f -name "*.toml" 2>/dev/null | grep -q .; then
        colorize red "Delete all tunnels first."
        sleep 3
        return 1
    fi
    colorize yellow "Remove ${BRAND} core? (y/n)"
    read -r confirm
    if [[ "$confirm" == [yY] ]]; then
        [[ -d "$config_dir" ]] && rm -rf "$config_dir"
        colorize green "${BRAND} core removed." bold
    fi
    press_key
}

# ────────────────────────────────────────────────────────────────
#  Self-update (fixed: now actually works)
# ────────────────────────────────────────────────────────────────
update_script() {
    local script_url="${GH_RAW}/backwall.sh"
    local tmp; tmp=$(mktemp)
    colorize cyan "Fetching latest script from GitHub..."
    if curl -fsSL --max-time 20 -o "$tmp" "$script_url"; then
        # sanity check: must look like our script
        if head -n 20 "$tmp" | grep -q "BackWall"; then
            install -m 0755 "$tmp" "$INSTALL_PATH"
            rm -f "$tmp"
            colorize green "Updated successfully. Run 'backwall' to start." bold
            exit 0
        else
            colorize red "Downloaded file does not look valid. Aborting."
        fi
    else
        colorize red "Download failed. Check your connection."
    fi
    rm -f "$tmp"
    press_key
}

configure_tunnel() {
    if [[ ! -d "$config_dir" ]]; then
        colorize red "Install ${BRAND} core first."
        press_key
        return 1
    fi
    clear
    echo ""
    colorize green   "1) Configure IRAN (Server)" bold
    colorize magenta "2) Configure KHAREJ (Client)" bold
    echo ""
    read -r -p "Enter your choice: " configure_choice
    case "$configure_choice" in
        1) configure_server "server" ;;
        2) configure_server "client" ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}

# ────────────────────────────────────────────────────────────────
#  Main menu
# ────────────────────────────────────────────────────────────────
display_menu() {
    clear
    display_logo
    display_server_info
    display_core_status
    echo
    echo -e "   \033[1;32m1\033[0m  Configure a new tunnel"
    echo -e "   \033[1;33m2\033[0m  Tunnel management"
    echo -e "   \033[1;36m3\033[0m  Check tunnel status"
    echo -e "   \033[0;37m4\033[0m  Update ${BRAND} core"
    echo -e "   \033[0;37m5\033[0m  Update script"
    echo -e "   \033[0;31m6\033[0m  Remove ${BRAND} core"
    echo -e "   \033[0;90m0\033[0m  Exit"
    _divider
}

read_option() {
    local choice
    read -r -p "Enter your choice [0-6]: " choice
    case "$choice" in
        1) configure_tunnel ;;
        2) tunnel_management ;;
        3) check_tunnel_status ;;
        4) download_and_extract_core "menu" ;;
        5) update_script ;;
        6) remove_core ;;
        0) exit 0 ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}

# ────────────────────────────────────────────────────────────────
#  Entry point
# ────────────────────────────────────────────────────────────────
main() {
    ensure_dependencies
    download_and_extract_core
    check_config_backup
    while true; do
        display_menu
        read_option
    done
}

main "$@"
