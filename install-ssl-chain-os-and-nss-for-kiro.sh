#!/usr/bin/env bash
# install-ssl-chain.sh
# Harvests the SSL certificate chain from a given URL and installs it into:
#   1. Ubuntu system CA bundle (via update-ca-certificates)
#   2. NSS database (for applications like Kiro/Electron that use libnss3)
#
# Usage: ./install-ssl-chain.sh <url>
# Example: ./install-ssl-chain.sh https://agenticore.lz.gov.il/lz-assist-gcp

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Argument validation ---
if [[ $# -lt 1 ]]; then
    error "Usage: $0 <url>"
    error "Example: $0 https://example.com"
    exit 1
fi

URL="$1"

# Extract host and port from URL
HOST=$(echo "$URL" | sed -E 's|^https?://||' | sed -E 's|/.*||' | sed -E 's|:.*||')
PORT=$(echo "$URL" | sed -E 's|^https?://||' | sed -E 's|/.*||' | grep -oP ':\K[0-9]+' || echo "443")

if [[ -z "$HOST" ]]; then
    error "Could not extract hostname from URL: $URL"
    exit 1
fi

info "Target: $HOST:$PORT"

# --- Check and install required tools ---
REQUIRED_TOOLS=("openssl" "certutil")
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    info "Missing tools: ${MISSING_TOOLS[*]}"
    info "Attempting to install..."

    PACKAGES=()
    for tool in "${MISSING_TOOLS[@]}"; do
        case "$tool" in
            openssl)   PACKAGES+=("openssl") ;;
            certutil)  PACKAGES+=("libnss3-tools") ;;
        esac
    done

    if ! sudo apt-get update -qq && sudo apt-get install -y -qq "${PACKAGES[@]}"; then
        error "Failed to install required packages: ${PACKAGES[*]}"
        error "Please install them manually and re-run this script."
        exit 1
    fi

    # Verify installation
    for tool in "${MISSING_TOOLS[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            error "Tool '$tool' still not available after installation attempt."
            exit 1
        fi
    done
    info "All required tools installed successfully."
fi

# --- Harvest the certificate chain ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

info "Connecting to $HOST:$PORT to retrieve certificate chain..."

CHAIN_PEM="$TMPDIR/chain.pem"
if ! openssl s_client -connect "$HOST:$PORT" -showcerts -servername "$HOST" </dev/null 2>/dev/null > "$CHAIN_PEM"; then
    error "Failed to connect to $HOST:$PORT"
    exit 1
fi

# Parse individual certificates from the chain
CERT_COUNT=0
CURRENT_CERT=""
IN_CERT=false

while IFS= read -r line; do
    if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
        IN_CERT=true
        CURRENT_CERT="$line"$'\n'
    elif [[ "$line" == "-----END CERTIFICATE-----" ]]; then
        CURRENT_CERT+="$line"$'\n'
        IN_CERT=false
        CERT_COUNT=$((CERT_COUNT + 1))
        echo -n "$CURRENT_CERT" > "$TMPDIR/cert-${CERT_COUNT}.pem"
        CURRENT_CERT=""
    elif [[ "$IN_CERT" == true ]]; then
        CURRENT_CERT+="$line"$'\n'
    fi
done < "$CHAIN_PEM"

if [[ $CERT_COUNT -eq 0 ]]; then
    error "No certificates received from $HOST:$PORT"
    exit 1
fi

info "Received $CERT_COUNT certificate(s) from server."

# --- Analyze the chain for completeness ---
# Check if chain is complete (last cert should be self-signed / root)
LAST_CERT="$TMPDIR/cert-${CERT_COUNT}.pem"
LAST_ISSUER=$(openssl x509 -in "$LAST_CERT" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
LAST_SUBJECT=$(openssl x509 -in "$LAST_CERT" -noout -subject 2>/dev/null | sed 's/^subject=//')

CHAIN_INCOMPLETE=false
if [[ "$LAST_ISSUER" != "$LAST_SUBJECT" ]]; then
    CHAIN_INCOMPLETE=true
    warn "=================================================================="
    warn "INCOMPLETE CHAIN DETECTED!"
    warn "The server did NOT send the full certificate chain."
    warn "Last certificate in chain:"
    warn "  Subject: $LAST_SUBJECT"
    warn "  Issuer:  $LAST_ISSUER"
    warn ""
    warn "The root CA certificate is missing from the server's response."
    warn "You may need to obtain the root CA manually from your IT team."
    warn "=================================================================="
fi

# Also verify chain linkage
if [[ $CERT_COUNT -gt 1 ]]; then
    for ((i = 1; i < CERT_COUNT; i++)); do
        CERT_ISSUER=$(openssl x509 -in "$TMPDIR/cert-${i}.pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
        NEXT_SUBJECT=$(openssl x509 -in "$TMPDIR/cert-$((i + 1)).pem" -noout -subject 2>/dev/null | sed 's/^subject=//')
        if [[ "$CERT_ISSUER" != "$NEXT_SUBJECT" ]]; then
            warn "Chain gap detected between cert $i and cert $((i + 1)):"
            warn "  Cert $i issuer:      $CERT_ISSUER"
            warn "  Cert $((i+1)) subject: $NEXT_SUBJECT"
            CHAIN_INCOMPLETE=true
        fi
    done
fi

# --- Skip the leaf (server) certificate, install intermediates and root ---
# Cert 1 is the leaf; certs 2..N are intermediates/root
if [[ $CERT_COUNT -lt 2 ]]; then
    warn "Only the leaf certificate was received (no intermediates/root)."
    warn "There is nothing to install into the CA trust store."
    if [[ "$CHAIN_INCOMPLETE" == true ]]; then
        error "Cannot proceed — the server only sent its own leaf certificate."
        error "Contact your IT team to obtain the CA chain for $HOST."
        exit 1
    fi
    exit 0
fi

# --- Install into Ubuntu CA bundle ---
info "Installing CA certificates into system trust store..."
INSTALLED_COUNT=0
SKIPPED_COUNT=0

CA_CERT_DIR="/usr/local/share/ca-certificates/${HOST}"
sudo mkdir -p "$CA_CERT_DIR"

for ((i = 2; i <= CERT_COUNT; i++)); do
    CERT_FILE="$TMPDIR/cert-${i}.pem"
    SUBJECT=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null | sed 's/^subject=//')
    FINGERPRINT=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')

    # Generate a safe filename from the subject CN or OU
    SAFE_NAME=$(echo "$SUBJECT" | grep -oP 'CN\s*=\s*\K[^,/]+' || echo "cert-${i}")
    SAFE_NAME=$(echo "$SAFE_NAME" | tr ' ' '-' | tr -cd '[:alnum:]_-' | head -c 60)
    DEST_FILE="${CA_CERT_DIR}/${SAFE_NAME}.crt"

    # Check if already installed (compare fingerprints of existing certs)
    ALREADY_INSTALLED=false
    if [[ -d "$CA_CERT_DIR" ]]; then
        shopt -s nullglob
        for existing in "$CA_CERT_DIR"/*.crt; do
            [[ -f "$existing" ]] || continue
            EXISTING_FP=$(openssl x509 -in "$existing" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')
            if [[ "$EXISTING_FP" == "$FINGERPRINT" ]]; then
                ALREADY_INSTALLED=true
                break
            fi
        done
        shopt -u nullglob
    fi

    # Also check the global ca-certificates bundle
    if [[ "$ALREADY_INSTALLED" == false ]]; then
        if openssl x509 -in "$CERT_FILE" -noout 2>/dev/null; then
            # Search system bundle for this fingerprint
            if grep -qF "$FINGERPRINT" <(find /etc/ssl/certs -name "*.pem" -exec openssl x509 -in {} -noout -fingerprint -sha256 2>/dev/null \;) 2>/dev/null; then
                ALREADY_INSTALLED=true
            fi
        fi
    fi

    if [[ "$ALREADY_INSTALLED" == true ]]; then
        info "  SKIP (already installed): $SUBJECT"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    else
        sudo cp "$CERT_FILE" "$DEST_FILE"
        info "  INSTALLED: $SUBJECT"
        info "    -> $DEST_FILE"
        INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
    fi
done

if [[ $INSTALLED_COUNT -gt 0 ]]; then
    info "Updating system CA bundle..."
    sudo update-ca-certificates
    info "System CA bundle updated."
else
    info "No new certificates to add to system CA bundle."
fi

# --- Install into NSS databases (for Electron/Kiro) ---
info "Installing into NSS databases..."

NSS_DBS=()
# Find all NSS cert9.db or cert8.db databases
while IFS= read -r db; do
    NSS_DBS+=("$(dirname "$db")")
done < <(find "$HOME" -name "cert9.db" -o -name "cert8.db" 2>/dev/null | sort -u)

# Also check common locations
for dir in "$HOME/.pki/nssdb" "$HOME/snap/kiro/common/.pki/nssdb"; do
    if [[ -d "$dir" ]]; then
        # Avoid duplicates
        if [[ ! " ${NSS_DBS[*]:-} " =~ " $dir " ]]; then
            NSS_DBS+=("$dir")
        fi
    fi
done

# Create default NSS db if none exist
if [[ ${#NSS_DBS[@]} -eq 0 ]]; then
    DEFAULT_NSS="$HOME/.pki/nssdb"
    info "No NSS database found. Creating one at $DEFAULT_NSS"
    mkdir -p "$DEFAULT_NSS"
    certutil -d sql:"$DEFAULT_NSS" -N --empty-password
    NSS_DBS+=("$DEFAULT_NSS")
fi

NSS_INSTALLED=0
NSS_SKIPPED=0

for ((i = 2; i <= CERT_COUNT; i++)); do
    CERT_FILE="$TMPDIR/cert-${i}.pem"
    SUBJECT=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null | sed 's/^subject=//')
    NICKNAME=$(echo "$SUBJECT" | grep -oP 'CN\s*=\s*\K[^,/]+' || echo "${HOST}-cert-${i}")

    for nssdb in "${NSS_DBS[@]}"; do
        # Determine db prefix (sql: for cert9.db, dbm: for cert8.db)
        if [[ -f "$nssdb/cert9.db" ]]; then
            DB_PREFIX="sql:$nssdb"
        elif [[ -f "$nssdb/cert8.db" ]]; then
            DB_PREFIX="dbm:$nssdb"
        else
            continue
        fi

        # Check if already in NSS db
        if certutil -d "$DB_PREFIX" -L -n "$NICKNAME" &>/dev/null; then
            info "  NSS SKIP (already in $nssdb): $NICKNAME"
            NSS_SKIPPED=$((NSS_SKIPPED + 1))
        else
            if certutil -d "$DB_PREFIX" -A -n "$NICKNAME" -t "CT,C,C" -i "$CERT_FILE" 2>/dev/null; then
                info "  NSS INSTALLED ($nssdb): $NICKNAME"
                NSS_INSTALLED=$((NSS_INSTALLED + 1))
            else
                warn "  NSS FAILED to install in $nssdb: $NICKNAME"
            fi
        fi
    done
done

# --- Summary ---
echo ""
info "==============================="
info "  SUMMARY"
info "==============================="
info "  Certificates received:       $CERT_COUNT (1 leaf + $((CERT_COUNT - 1)) CA)"
info "  System CA - installed:       $INSTALLED_COUNT"
info "  System CA - skipped (dupes): $SKIPPED_COUNT"
info "  NSS DB    - installed:       $NSS_INSTALLED"
info "  NSS DB    - skipped (dupes): $NSS_SKIPPED"
if [[ "$CHAIN_INCOMPLETE" == true ]]; then
    warn "  Chain status:                INCOMPLETE (see warnings above)"
else
    info "  Chain status:                COMPLETE"
fi
info "==============================="
echo ""
info "Restart Kiro IDE for changes to take effect."
if [[ "$CHAIN_INCOMPLETE" == true ]]; then
    warn "If SSL still fails after restart, you may need to obtain the missing"
    warn "root CA certificate from your IT/security team and re-run this script"
    warn "with the full chain, or manually place the root CA in:"
    warn "  /usr/local/share/ca-certificates/"
fi
