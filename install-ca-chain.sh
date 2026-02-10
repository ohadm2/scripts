#!/bin/bash
set -euo pipefail

# Unified CA Chain Installer
# Downloads CA chain from a site and installs it system-wide

SCRIPT_NAME=$(basename "$0")
CERTS_DIR="${CERTS_DIR:-/tmp/ca-certs}"
BACKUP_SUFFIX="backup-$(date +%Y%m%d-%H%M%S)"
DEFAULT_DOMAIN="google.com"

# CA bundle locations for different tools
CA_BUNDLES=(
    "/etc/ssl/certs/ca-bundle.crt"                                      # CentOS/RHEL
    "/etc/ssl/certs/ca-certificates.crt"                                # Debian/Ubuntu
    "/etc/pki/tls/certs/ca-bundle.crt"                                  # CentOS/RHEL alt
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"                # CentOS/RHEL
)

# Python certifi locations (will be auto-detected)
PYTHON_PATHS=()

# Ruby SSL certs locations
RUBY_PATHS=()

# Node.js CA locations
NODE_PATHS=()

# Java cacerts locations
JAVA_CACERTS=()

# PHP cacert locations
PHP_CACERTS=()

# Git config
GIT_CONFIG="/etc/gitconfig"

# Docker daemon config
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"

# gcloud SDK paths
GCLOUD_PATHS=()

# AWS CLI paths
AWS_PATHS=()

# Composer paths
COMPOSER_PATHS=()

# wget config
WGET_CONFIG="/etc/wgetrc"

# curl config
CURL_CA_BUNDLE="/etc/ssl/certs/ca-bundle.crt"

# MinGW/msys2
MINGW_PATHS=()

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [domain]

Download CA certificate chain from a domain and install it system-wide.

Arguments:
    domain          Domain to fetch certificates from (default: $DEFAULT_DOMAIN)
                    Do NOT include http:// or https://

Options:
    -h, --help      Show this help message
    -d, --dir DIR   Directory to store certificates (default: $CERTS_DIR)
    -p, --port PORT Port to connect to (default: 443)
    --skip-system   Skip system CA bundle installation
    --skip-python   Skip Python certifi installation
    --skip-ruby     Skip Ruby installation
    --skip-node     Skip Node.js installation
    --skip-java     Skip Java cacerts installation
    --skip-php      Skip PHP installation
    --skip-git      Skip Git configuration
    --skip-docker   Skip Docker configuration
    --skip-gcloud   Skip Google Cloud SDK installation
    --skip-aws      Skip AWS CLI installation
    --skip-composer Skip Composer installation
    --skip-wget     Skip wget configuration
    --skip-curl     Skip curl configuration

Examples:
    $SCRIPT_NAME
    $SCRIPT_NAME gitlab.example.com
    $SCRIPT_NAME --dir /opt/certs google.com
    $SCRIPT_NAME --skip-python --skip-node internal.corp.com

EOF
    exit 0
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

error() {
    log "ERROR: $*"
    exit 1
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp -v "$file" "${file}.${BACKUP_SUFFIX}"
        log "Backed up: $file"
    fi
}

download_cert_chain() {
    local domain="$1"
    local port="${2:-443}"
    
    log "Downloading certificate chain from ${domain}:${port}..."
    
    mkdir -p "$CERTS_DIR"
    cd "$CERTS_DIR"
    
    # Get certificate chain
    local certs
    certs=$(openssl s_client -showcerts -verify 5 -connect "${domain}:${port}" 2>/dev/null </dev/null \
        | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p')
    
    if [[ -z "$certs" ]]; then
        error "Failed to download certificates from ${domain}:${port}"
    fi
    
    # Parse certificates
    local cert_num=1
    local current_cert=""
    local in_cert=false
    local cert_files=()
    
    while IFS= read -r line; do
        if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
            in_cert=true
            current_cert="$line"
        elif [[ "$line" == "-----END CERTIFICATE-----" ]]; then
            current_cert+=$'\n'"$line"
            
            local cert_file="${domain}_${cert_num}.pem"
            echo "$current_cert" > "$cert_file"
            
            # Get cert info
            local subject
            subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/subject=//')
            local issuer
            issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/issuer=//')
            
            log "Certificate $cert_num: $cert_file"
            log "  Subject: $subject"
            log "  Issuer:  $issuer"
            
            cert_files+=("$cert_file")
            ((cert_num++))
            in_cert=false
            current_cert=""
        elif [[ "$in_cert" == true ]]; then
            current_cert+=$'\n'"$line"
        fi
    done <<< "$certs"
    
    # Remove end certificate (keep only CA chain)
    if [[ ${#cert_files[@]} -gt 1 ]]; then
        log "Removing end certificate: ${cert_files[0]}"
        rm -f "${cert_files[0]}"
        unset 'cert_files[0]'
    fi
    
    if [[ ${#cert_files[@]} -eq 0 ]]; then
        error "No CA certificates found in chain"
    fi
    
    # Create combined CA bundle
    cat "${cert_files[@]}" > "${domain}_ca_chain.pem"
    log "Created CA chain bundle: ${domain}_ca_chain.pem"
    
    echo "${domain}_ca_chain.pem"
}

detect_python_certifi() {
    log "Detecting Python certifi locations..."
    
    for python_cmd in python3 python python2; do
        if command -v "$python_cmd" &>/dev/null; then
            local certifi_path
            certifi_path=$("$python_cmd" -c "import certifi; print(certifi.where())" 2>/dev/null || true)
            if [[ -n "$certifi_path" && -f "$certifi_path" ]]; then
                PYTHON_PATHS+=("$certifi_path")
                log "Found Python certifi: $certifi_path ($python_cmd)"
            fi
            
            # Also check pip vendor certifi
            local pip_certifi
            pip_certifi=$("$python_cmd" -c "import pip._vendor.certifi as c; print(c.where())" 2>/dev/null || true)
            if [[ -n "$pip_certifi" && -f "$pip_certifi" && "$pip_certifi" != "$certifi_path" ]]; then
                PYTHON_PATHS+=("$pip_certifi")
                log "Found pip certifi: $pip_certifi ($python_cmd)"
            fi
        fi
    done
}

detect_ruby_certs() {
    log "Detecting Ruby SSL cert locations..."
    
    if command -v ruby &>/dev/null; then
        local ruby_cert_file
        ruby_cert_file=$(ruby -ropenssl -e 'p OpenSSL::X509::DEFAULT_CERT_FILE' 2>/dev/null | tr -d '"' || true)
        if [[ -n "$ruby_cert_file" && -f "$ruby_cert_file" ]]; then
            RUBY_PATHS+=("$ruby_cert_file")
            log "Found Ruby cert file: $ruby_cert_file"
        fi
        
        # Check gem SSL certs directory
        local ruby_version
        ruby_version=$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)
        if [[ -n "$ruby_version" ]]; then
            local gem_ssl_dir="/usr/lib/ruby/${ruby_version}/rubygems/ssl_certs"
            if [[ -d "$gem_ssl_dir" ]]; then
                RUBY_PATHS+=("$gem_ssl_dir")
                log "Found Ruby gem SSL dir: $gem_ssl_dir"
            fi
        fi
    fi
}

detect_node_ca() {
    log "Detecting Node.js CA locations..."
    
    if command -v node &>/dev/null; then
        log "Node.js detected - will use NODE_EXTRA_CA_CERTS environment variable"
    fi
}

detect_java_cacerts() {
    log "Detecting Java cacerts..."
    
    JAVA_CACERTS=()
    
    if command -v java &>/dev/null; then
        local java_home
        java_home=$(java -XshowSettings:properties -version 2>&1 | grep 'java.home' | awk '{print $3}' || true)
        if [[ -n "$java_home" ]]; then
            local cacerts="${java_home}/lib/security/cacerts"
            if [[ -f "$cacerts" ]]; then
                JAVA_CACERTS+=("$cacerts")
                log "Found Java cacerts: $cacerts"
            fi
        fi
    fi
    
    # Fallback locations
    for path in "/etc/pki/ca-trust/extracted/java/cacerts" \
                "/usr/lib/jvm/default-java/jre/lib/security/cacerts" \
                "/usr/lib/jvm/java-11-openjdk-amd64/lib/security/cacerts"; do
        if [[ -f "$path" ]] && [[ ! " ${JAVA_CACERTS[@]} " =~ " ${path} " ]]; then
            JAVA_CACERTS+=("$path")
            log "Found Java cacerts: $path"
        fi
    done
}

detect_php_cacerts() {
    log "Detecting PHP cacert locations..."
    
    if command -v php &>/dev/null; then
        local php_ini
        php_ini=$(php -i 2>/dev/null | grep 'Loaded Configuration File' | awk '{print $5}' || true)
        if [[ -n "$php_ini" && -f "$php_ini" ]]; then
            log "Found PHP ini: $php_ini"
            
            # Check for openssl.cafile setting
            local cafile
            cafile=$(php -i 2>/dev/null | grep 'openssl.cafile' | awk '{print $3}' || true)
            if [[ -n "$cafile" && "$cafile" != "no value" ]]; then
                PHP_CACERTS+=("$cafile")
                log "Found PHP openssl.cafile: $cafile"
            fi
        fi
    fi
}

detect_gcloud_certs() {
    log "Detecting Google Cloud SDK cert locations..."
    
    if command -v gcloud &>/dev/null; then
        local gcloud_root
        gcloud_root=$(gcloud info --format="value(installation.sdk_root)" 2>/dev/null || true)
        if [[ -n "$gcloud_root" ]]; then
            for path in "${gcloud_root}/lib/third_party/certifi/cacert.pem" \
                        "${gcloud_root}/lib/third_party/botocore/cacert.pem" \
                        "${gcloud_root}/lib/third_party/requests/cacert.pem"; do
                if [[ -f "$path" ]]; then
                    GCLOUD_PATHS+=("$path")
                    log "Found gcloud cert: $path"
                fi
            done
        fi
    fi
}

detect_aws_certs() {
    log "Detecting AWS CLI cert locations..."
    
    if command -v aws &>/dev/null; then
        for path in "/usr/lib/python3/dist-packages/botocore/cacert.pem" \
                    "/usr/local/lib/python3.*/dist-packages/botocore/cacert.pem"; do
            if [[ -f "$path" ]]; then
                AWS_PATHS+=("$path")
                log "Found AWS CLI cert: $path"
            fi
        done
    fi
}

detect_composer_certs() {
    log "Detecting Composer cert locations..."
    
    if command -v composer &>/dev/null; then
        local cafile
        cafile=$(composer config --global cafile 2>/dev/null || true)
        if [[ -n "$cafile" && -f "$cafile" ]]; then
            COMPOSER_PATHS+=("$cafile")
            log "Found Composer cafile: $cafile"
        fi
    fi
}

detect_mingw_certs() {
    log "Detecting MinGW/msys2 cert locations..."
    
    for path in "/usr/ssl/certs/ca-bundle.crt" \
                "/mingw64/ssl/certs/ca-bundle.crt"; do
        if [[ -f "$path" ]]; then
            MINGW_PATHS+=("$path")
            log "Found MinGW cert: $path"
        fi
    done
}

install_system_ca() {
    local ca_bundle="$1"
    
    log "Installing to system CA bundles..."
    
    for bundle in "${CA_BUNDLES[@]}"; do
        if [[ -f "$bundle" ]]; then
            backup_file "$bundle"
            cat "$ca_bundle" >> "$bundle"
            log "Installed to: $bundle"
        fi
    done
    
    # Install to ca-certificates directory
    if [[ -d "/usr/local/share/ca-certificates" ]]; then
        cp "$ca_bundle" "/usr/local/share/ca-certificates/$(basename "$ca_bundle" .pem).crt"
        log "Copied to: /usr/local/share/ca-certificates/"
        
        if command -v update-ca-certificates &>/dev/null; then
            log "Running update-ca-certificates..."
            update-ca-certificates --fresh
        fi
    fi
}

install_python_ca() {
    local ca_bundle="$1"
    
    if [[ ${#PYTHON_PATHS[@]} -eq 0 ]]; then
        log "No Python certifi installations found"
        return
    fi
    
    log "Installing to Python certifi..."
    
    for certifi_path in "${PYTHON_PATHS[@]}"; do
        backup_file "$certifi_path"
        cat "$ca_bundle" >> "$certifi_path"
        log "Installed to: $certifi_path"
    done
}

install_ruby_ca() {
    local ca_bundle="$1"
    
    if [[ ${#RUBY_PATHS[@]} -eq 0 ]]; then
        log "No Ruby installations found"
        return
    fi
    
    log "Installing to Ruby..."
    
    for ruby_path in "${RUBY_PATHS[@]}"; do
        if [[ -d "$ruby_path" ]]; then
            # It's a directory, copy individual certs
            cp "$ca_bundle" "${ruby_path}/$(basename "$ca_bundle")"
            log "Copied to Ruby SSL dir: $ruby_path"
        elif [[ -f "$ruby_path" ]]; then
            # It's a file, append
            backup_file "$ruby_path"
            cat "$ca_bundle" >> "$ruby_path"
            log "Installed to: $ruby_path"
        fi
    done
}

install_php_ca() {
    local ca_bundle="$1"
    
    if ! command -v php &>/dev/null; then
        log "PHP not found"
        return
    fi
    
    log "Configuring PHP..."
    
    local php_ini
    php_ini=$(php -i 2>/dev/null | grep 'Loaded Configuration File' | awk '{print $5}' || true)
    
    if [[ -n "$php_ini" && -f "$php_ini" ]]; then
        backup_file "$php_ini"
        
        # Update or add openssl.cafile
        if grep -q "^openssl.cafile" "$php_ini"; then
            sed -i "s|^openssl.cafile.*|openssl.cafile=\"$ca_bundle\"|" "$php_ini"
        else
            echo "openssl.cafile=\"$ca_bundle\"" >> "$php_ini"
        fi
        
        log "Updated PHP openssl.cafile in: $php_ini"
    fi
    
    # Install to detected PHP cacerts
    for cacert in "${PHP_CACERTS[@]}"; do
        if [[ -f "$cacert" ]]; then
            backup_file "$cacert"
            cat "$ca_bundle" >> "$cacert"
            log "Installed to: $cacert"
        fi
    done
}

install_gcloud_ca() {
    local ca_bundle="$1"
    
    if [[ ${#GCLOUD_PATHS[@]} -eq 0 ]]; then
        log "Google Cloud SDK not found"
        return
    fi
    
    log "Installing to Google Cloud SDK..."
    
    for gcloud_cert in "${GCLOUD_PATHS[@]}"; do
        backup_file "$gcloud_cert"
        cat "$ca_bundle" >> "$gcloud_cert"
        log "Installed to: $gcloud_cert"
    done
}

install_aws_ca() {
    local ca_bundle="$1"
    
    if [[ ${#AWS_PATHS[@]} -eq 0 ]]; then
        log "AWS CLI not found"
        return
    fi
    
    log "Installing to AWS CLI..."
    
    for aws_cert in "${AWS_PATHS[@]}"; do
        backup_file "$aws_cert"
        cat "$ca_bundle" >> "$aws_cert"
        log "Installed to: $aws_cert"
    done
    
    # Set AWS_CA_BUNDLE environment variable
    local profile_file="/etc/profile.d/aws-ca.sh"
    cat > "$profile_file" <<EOF
# Added by $SCRIPT_NAME
export AWS_CA_BUNDLE="$ca_bundle"
EOF
    chmod +x "$profile_file"
    log "Created: $profile_file"
}

install_composer_ca() {
    local ca_bundle="$1"
    
    if ! command -v composer &>/dev/null; then
        log "Composer not found"
        return
    fi
    
    log "Configuring Composer..."
    
    composer config --global cafile "$ca_bundle"
    log "Set Composer cafile to: $ca_bundle"
}

configure_wget() {
    local ca_bundle="$1"
    
    if ! command -v wget &>/dev/null; then
        log "wget not found"
        return
    fi
    
    log "Configuring wget..."
    
    if [[ -f "$WGET_CONFIG" ]]; then
        backup_file "$WGET_CONFIG"
        
        # Update or add ca_certificate
        if grep -q "^ca_certificate" "$WGET_CONFIG"; then
            sed -i "s|^ca_certificate.*|ca_certificate = $ca_bundle|" "$WGET_CONFIG"
        else
            echo "ca_certificate = $ca_bundle" >> "$WGET_CONFIG"
        fi
        
        log "Updated wget config: $WGET_CONFIG"
    fi
}

configure_curl() {
    local ca_bundle="$1"
    
    if ! command -v curl &>/dev/null; then
        log "curl not found"
        return
    fi
    
    log "Configuring curl..."
    
    # Set CURL_CA_BUNDLE environment variable
    local profile_file="/etc/profile.d/curl-ca.sh"
    cat > "$profile_file" <<EOF
# Added by $SCRIPT_NAME
export CURL_CA_BUNDLE="$ca_bundle"
EOF
    chmod +x "$profile_file"
    log "Created: $profile_file"
}

install_mingw_ca() {
    local ca_bundle="$1"
    
    if [[ ${#MINGW_PATHS[@]} -eq 0 ]]; then
        log "MinGW/msys2 not found"
        return
    fi
    
    log "Installing to MinGW/msys2..."
    
    for mingw_cert in "${MINGW_PATHS[@]}"; do
        backup_file "$mingw_cert"
        cat "$ca_bundle" >> "$mingw_cert"
        log "Installed to: $mingw_cert"
    done
}

install_node_ca() {
    local ca_bundle="$1"
    
    if ! command -v node &>/dev/null; then
        log "Node.js not found"
        return
    fi
    
    log "Configuring Node.js CA..."
    
    # Set NODE_EXTRA_CA_CERTS in profile
    local profile_file="/etc/profile.d/node-ca.sh"
    cat > "$profile_file" <<EOF
# Added by $SCRIPT_NAME
export NODE_EXTRA_CA_CERTS="$ca_bundle"
EOF
    chmod +x "$profile_file"
    log "Created: $profile_file"
}

install_ruby_ca() {
    local ca_bundle="$1"
    
    if ! command -v keytool &>/dev/null; then
        log "Java keytool not found"
        return
    fi
    
    log "Installing to Java cacerts..."
    
    # Extract individual certs and import
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    csplit -f cert- -z "$ca_bundle" '/-----BEGIN CERTIFICATE-----/' '{*}' &>/dev/null || true
    
    for cacerts in "${JAVA_CACERTS[@]}"; do
        if [[ -f "$cacerts" ]]; then
            backup_file "$cacerts"
            
            local cert_num=1
            for cert_file in cert-*; do
                [[ -f "$cert_file" ]] || continue
                
                local alias="custom-ca-${cert_num}"
                keytool -import -trustcacerts -alias "$alias" -file "$cert_file" \
                    -keystore "$cacerts" -storepass changeit -noprompt 2>/dev/null || true
                ((cert_num++))
            done
            
            log "Installed to: $cacerts"
        fi
    done
    
    cd - >/dev/null
    rm -rf "$temp_dir"
}

configure_git() {
    local ca_bundle="$1"
    
    if ! command -v git &>/dev/null; then
        log "Git not found"
        return
    fi
    
    log "Configuring Git..."
    
    git config --system http.sslCAInfo "$ca_bundle"
    log "Set git http.sslCAInfo to: $ca_bundle"
}

configure_docker() {
    local ca_bundle="$1"
    
    if ! command -v docker &>/dev/null; then
        log "Docker not found"
        return
    fi
    
    log "Configuring Docker..."
    
    # Copy CA to Docker certs directory
    local docker_certs_dir="/etc/docker/certs.d"
    mkdir -p "$docker_certs_dir"
    cp "$ca_bundle" "${docker_certs_dir}/ca.crt"
    log "Copied to: ${docker_certs_dir}/ca.crt"
}

main() {
    local domain="$DEFAULT_DOMAIN"
    local port=443
    local skip_system=false
    local skip_python=false
    local skip_ruby=false
    local skip_node=false
    local skip_java=false
    local skip_php=false
    local skip_git=false
    local skip_docker=false
    local skip_gcloud=false
    local skip_aws=false
    local skip_composer=false
    local skip_wget=false
    local skip_curl=false
    local skip_mingw=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -d|--dir)
                CERTS_DIR="$2"
                shift 2
                ;;
            -p|--port)
                port="$2"
                shift 2
                ;;
            --skip-system)
                skip_system=true
                shift
                ;;
            --skip-python)
                skip_python=true
                shift
                ;;
            --skip-ruby)
                skip_ruby=true
                shift
                ;;
            --skip-node)
                skip_node=true
                shift
                ;;
            --skip-java)
                skip_java=true
                shift
                ;;
            --skip-php)
                skip_php=true
                shift
                ;;
            --skip-git)
                skip_git=true
                shift
                ;;
            --skip-docker)
                skip_docker=true
                shift
                ;;
            --skip-gcloud)
                skip_gcloud=true
                shift
                ;;
            --skip-aws)
                skip_aws=true
                shift
                ;;
            --skip-composer)
                skip_composer=true
                shift
                ;;
            --skip-wget)
                skip_wget=true
                shift
                ;;
            --skip-curl)
                skip_curl=true
                shift
                ;;
            --skip-mingw)
                skip_mingw=true
                shift
                ;;
            -*)
                error "Unknown option: $1"
                ;;
            *)
                domain="$1"
                shift
                ;;
        esac
    done
    
    # Check for root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
    
    log "Starting CA chain installation for: $domain"
    
    # Download certificates
    local ca_bundle
    ca_bundle=$(download_cert_chain "$domain" "$port")
    ca_bundle="${CERTS_DIR}/${ca_bundle}"
    
    # Detect installations
    [[ "$skip_python" == false ]] && detect_python_certifi
    [[ "$skip_ruby" == false ]] && detect_ruby_certs
    [[ "$skip_node" == false ]] && detect_node_ca
    [[ "$skip_java" == false ]] && detect_java_cacerts
    [[ "$skip_php" == false ]] && detect_php_cacerts
    [[ "$skip_gcloud" == false ]] && detect_gcloud_certs
    [[ "$skip_aws" == false ]] && detect_aws_certs
    [[ "$skip_composer" == false ]] && detect_composer_certs
    [[ "$skip_mingw" == false ]] && detect_mingw_certs
    
    # Install certificates
    [[ "$skip_system" == false ]] && install_system_ca "$ca_bundle"
    [[ "$skip_python" == false ]] && install_python_ca "$ca_bundle"
    [[ "$skip_ruby" == false ]] && install_ruby_ca "$ca_bundle"
    [[ "$skip_node" == false ]] && install_node_ca "$ca_bundle"
    [[ "$skip_java" == false ]] && install_java_ca "$ca_bundle"
    [[ "$skip_php" == false ]] && install_php_ca "$ca_bundle"
    [[ "$skip_git" == false ]] && configure_git "$ca_bundle"
    [[ "$skip_docker" == false ]] && configure_docker "$ca_bundle"
    [[ "$skip_gcloud" == false ]] && install_gcloud_ca "$ca_bundle"
    [[ "$skip_aws" == false ]] && install_aws_ca "$ca_bundle"
    [[ "$skip_composer" == false ]] && install_composer_ca "$ca_bundle"
    [[ "$skip_wget" == false ]] && configure_wget "$ca_bundle"
    [[ "$skip_curl" == false ]] && configure_curl "$ca_bundle"
    [[ "$skip_mingw" == false ]] && install_mingw_ca "$ca_bundle"
    
    log "CA chain installation completed successfully!"
    log "Certificates stored in: $CERTS_DIR"
    log "CA bundle: $ca_bundle"
    log ""
    log "Environment variables set in /etc/profile.d/ for:"
    log "  - Node.js (NODE_EXTRA_CA_CERTS)"
    log "  - AWS CLI (AWS_CA_BUNDLE)"
    log "  - curl (CURL_CA_BUNDLE)"
    log ""
    log "You may need to restart services or re-login for changes to take effect."
}

main "$@"
