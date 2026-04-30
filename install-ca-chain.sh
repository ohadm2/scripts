#!/bin/bash
set -euo pipefail

# Unified CA Chain Installer
# Downloads CA chain from a site and installs it system-wide

SCRIPT_NAME=$(basename "$0")
CERTS_DIR="${CERTS_DIR:-/tmp/ca-certs}"
BACKUP_SUFFIX="backup-$(date +%Y%m%d-%H%M%S)"
DEFAULT_DOMAIN="google.com"

# BlueCoat Cloud Services Root CA
# This root CA is appended to incomplete certificate chains
ROOT_CA_CERT='-----BEGIN CERTIFICATE-----
MIIDkjCCAnqgAwIBAgIQYh7PD8WR0TDUDVENFkFmfDANBgkqhkiG9w0BAQsFADBP
MQswCQYDVQQGEwJVUzEfMB0GA1UEChMWQmx1ZUNvYXQgU3lzdGVtcywgSW5jLjEf
MB0GA1UEAxMWQ2xvdWQgU2VydmljZXMgUm9vdCBDQTAeFw0xMTA5MDYwMDAwMDBa
Fw0zNjA5MDUyMzU5NTlaME8xCzAJBgNVBAYTAlVTMR8wHQYDVQQKExZCbHVlQ29h
dCBTeXN0ZW1zLCBJbmMuMR8wHQYDVQQDExZDbG91ZCBTZXJ2aWNlcyBSb290IENB
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxAB79qIpN0NApUS0be0N
FYDqnY3g9jJsYZ6HVRsbw2eJnO2BKYhoBOW5fmUc9FaT0VbhIokHFRj4w3c2keWV
gTlFHbp6EZaaK1H8yczTf57WlXILuCrJ9eGYsWE2doJePnFpT1QejDRQYMKTjAfQ
A0twCBSxxmZ5TzEJ/xAu4cYTc3CnMrgA3n+/tcH7Yn5PDNGAiwZMWf5OPbktH33b
2r7yex+bgXXivY1Mw6k82RYLTLRsa8AoluBDTplqMbHo1QE7AuveeFkLL5GXX/8U
xao0mBvud2NJCHTZ9EcyHn5/Y2gnqJW4tmbMNXrrhAE+5Y1dWMAU8QFSF0aszQQE
2wIDAQABo2owaDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAmBgNV
HREEHzAdpBswGTEXMBUGA1UEAxMOTVBLSS0yMDQ4LTEtOTkwHQYDVR0OBBYEFKZK
F9G8WLV3JRaSK9JMlSPPKBQ2MA0GCSqGSIb3DQEBCwUAA4IBAQCJszHQDBq6Flgo
NRcgmgfn8LvyT1kWmBvM5UdZbPJwquKt4eqz67lXKzEnIUcWwdnJnkt0gmzXLw0z
N5jwISiDbV5iGuJp6x+ftwwvHf9WxqM/aF9xQ9V5767GP4HCz0XfVcx0A1h+nJnh
2suSISN6rPFhIhC5r/hbmBzzs/mjj60wFACDoP13Q2U3D+Jwm3Gf+LjQNHfLfPcB
rJx9hKP8MJEDYPjHyLZTPd9keF3YfG5JevANWIK+4gzgbeVaLEV9/yXWRNEYxYhC
y1nLwUcano2K8mgWkbUHctv7xw/SGymDCIrDnkHBrHqQ59YEfXWBZlLR0gyY56S1
X7G8bD+o
-----END CERTIFICATE-----'

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
    --skip-venv     Skip Python virtual environment detection
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
    --cloud-func LANG
                    Print the proxy cert helper code for the given language
                    and exit (does not require root). Supported languages:
                    python3.12, python3.13, nodejs, go, java, dotnet, php, ruby.
                    Redirect the output to a file to save it.
                    For PHP, both proxy_cert_setup.php and php.ini are
                    printed together with clear separators.

Examples:
    $SCRIPT_NAME
    $SCRIPT_NAME gitlab.example.com
    $SCRIPT_NAME --dir /opt/certs google.com
    $SCRIPT_NAME --skip-python --skip-node internal.corp.com
    $SCRIPT_NAME --cloud-func python3.12 > proxy_cert_setup.py
    $SCRIPT_NAME --cloud-func nodejs > proxyCertSetup.js
    $SCRIPT_NAME --cloud-func go     > proxycerts.go
    $SCRIPT_NAME --cloud-func java   > ProxyCertSetup.java
    $SCRIPT_NAME --cloud-func dotnet > ProxyCertSetup.cs
    $SCRIPT_NAME --cloud-func php    # outputs both .php and .ini
    $SCRIPT_NAME --cloud-func ruby   > proxy_cert_setup.rb

EOF
    exit 0
}

# ---------------------------------------------------------------------------
# --cloud-func: print the proxy cert helper code for a given language
# ---------------------------------------------------------------------------
cloud_func_snippet() {
    local lang="$1"
    case "$lang" in

    # -----------------------------------------------------------------------
    python3.12)
        cat <<'PYEOF'
# first, connect to google and get the CA certificates
# then, connect the CA certificates to regular certificates package of python
# finally, set to system to use the new package
import socket
import ssl
import tempfile
import os
import certifi
import sys

_CERT_LOADED = False
_CERT_BUNDLE_PATH = None

# Embedded root CA certificate for proxy
ROOT_CA_CERT = """-----BEGIN CERTIFICATE-----
MIIDkjCCAnqgAwIBAgIQYh7PD8WR0TDUDVENFkFmfDANBgkqhkiG9w0BAQsFADBP
MQswCQYDVQQGEwJVUzEfMB0GA1UEChMWQmx1ZUNvYXQgU3lzdGVtcywgSW5jLjEf
MB0GA1UEAxMWQ2xvdWQgU2VydmljZXMgUm9vdCBDQTAeFw0xMTA5MDYwMDAwMDBa
Fw0zNjA5MDUyMzU5NTlaME8xCzAJBgNVBAYTAlVTMR8wHQYDVQQKExZCbHVlQ29h
dCBTeXN0ZW1zLCBJbmMuMR8wHQYDVQQDExZDbG91ZCBTZXJ2aWNlcyBSb290IENB
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxAB79qIpN0NApUS0be0N
FYDqnY3g9jJsYZ6HVRsbw2eJnO2BKYhoBOW5fmUc9FaT0VbhIokHFRj4w3c2keWV
gTlFHbp6EZaaK1H8yczTf57WlXILuCrJ9eGYsWE2doJePnFpT1QejDRQYMKTjAfQ
A0twCBSxxmZ5TzEJ/xAu4cYTc3CnMrgA3n+/tcH7Yn5PDNGAiwZMWf5OPbktH33b
2r7yex+bgXXivY1Mw6k82RYLTLRsa8AoluBDTplqMbHo1QE7AuveeFkLL5GXX/8U
xao0mBvud2NJCHTZ9EcyHn5/Y2gnqJW4tmbMNXrrhAE+5Y1dWMAU8QFSF0aszQQE
2wIDAQABo2owaDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAmBgNV
HREEHzAdpBswGTEXMBUGA1UEAxMOTVBLSS0yMDQ4LTEtOTkwHQYDVR0OBBYEFKZK
F9G8WLV3JRaSK9JMlSPPKBQ2MA0GCSqGSIb3DQEBCwUAA4IBAQCJszHQDBq6Flgo
NRcgmgfn8LvyT1kWmBvM5UdZbPJwquKt4eqz67lXKzEnIUcWwdnJnkt0gmzXLw0z
N5jwISiDbV5iGuJp6x+ftwwvHf9WxqM/aF9xQ9V5767GP4HCz0XfVcx0A1h+nJnh
2suSISN6rPFhIhC5r/hbmBzzs/mjj60wFACDoP13Q2U3D+Jwm3Gf+LjQNHfLfPcB
rJx9hKP8MJEDYPjHyLZTPd9keF3YfG5JevANWIK+4gzgbeVaLEV9/yXWRNEYxYhC
y1nLwUcano2K8mgWkbUHctv7xw/SGymDCIrDnkHBrHqQ59YEfXWBZlLR0gyY56S1
X7G8bD+o
-----END CERTIFICATE-----
"""

print(f"🔍 [DEBUG] Python version: {sys.version}", flush=True)
print(f"🔍 [DEBUG] SSL version: {ssl.OPENSSL_VERSION}", flush=True)
print(f"🔍 [DEBUG] SSL version: {ssl.OPENSSL_VERSION}", flush=True)

def get_proxy_certs(domain="google.com", port=443):
    print(f"🔍 [DEBUG] Connecting to {domain}:{port} to fetch proxy certs...", flush=True)
    
    certs = []
    
    try:
        # Create raw socket connection
        sock = socket.create_connection((domain, port), timeout=10)
        print(f"🔍 [DEBUG] Socket connected to {domain}:{port}", flush=True)
        
        # Create SSL context that doesn't verify
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        
        # Wrap socket with SSL
        ssock = ctx.wrap_socket(sock, server_hostname=domain)
        print(f"🔍 [DEBUG] SSL handshake complete", flush=True)
        
        # Get certificate chain
        ssl_obj = ssock._sslobj
        
        if hasattr(ssl_obj, 'get_unverified_chain'):
            print(f"🔍 [DEBUG] Using get_unverified_chain()", flush=True)
            cert_chain = ssl_obj.get_unverified_chain()
            
            for i, cert_obj in enumerate(cert_chain):
                # _ssl.Certificate.public_bytes() returns PEM bytes
                pem_bytes = cert_obj.public_bytes()
                if isinstance(pem_bytes, bytes):
                    certs.append(pem_bytes.decode('utf-8'))
                else:
                    certs.append(pem_bytes)
                print(f"🔍 [DEBUG] Extracted cert {i+1} from unverified chain", flush=True)
        
        elif hasattr(ssl_obj, 'get_verified_chain'):
            print(f"🔍 [DEBUG] Using get_verified_chain()", flush=True)
            cert_chain = ssl_obj.get_verified_chain()
            
            for i, cert_obj in enumerate(cert_chain):
                pem_bytes = cert_obj.public_bytes()
                if isinstance(pem_bytes, bytes):
                    certs.append(pem_bytes.decode('utf-8'))
                else:
                    certs.append(pem_bytes)
                print(f"🔍 [DEBUG] Extracted cert {i+1} from verified chain", flush=True)
        
        else:
            # Fallback: just get the peer cert
            print(f"🔍 [DEBUG] No chain method available, using getpeercert", flush=True)
            der_cert = ssock.getpeercert(binary_form=True)
            from cryptography import x509
            from cryptography.hazmat.backends import default_backend
            from cryptography.hazmat.primitives import serialization
            
            peer_cert = x509.load_der_x509_certificate(der_cert, default_backend())
            pem_bytes = peer_cert.public_bytes(serialization.Encoding.PEM)
            certs.append(pem_bytes.decode('utf-8'))
        
        ssock.close()
        sock.close()
        
    except Exception as e:
        print(f"⚠️ [DEBUG] Failed to extract certs: {e}", flush=True)
        import traceback
        traceback.print_exc()
    
    print(f"🔍 [DEBUG] Total certs extracted: {len(certs)}", flush=True)
    
    # Debug: parse and show cert details
    try:
        from cryptography import x509
        from cryptography.hazmat.backends import default_backend
        
        for i, cert_pem in enumerate(certs):
            try:
                cert = x509.load_pem_x509_certificate(cert_pem.encode('utf-8'), default_backend())
                subject = cert.subject.rfc4514_string()
                issuer = cert.issuer.rfc4514_string()
                print(f"🔍 [DEBUG] Cert {i+1}:", flush=True)
                print(f"   Subject: {subject}", flush=True)
                print(f"   Issuer: {issuer}", flush=True)
                print(f"   Self-signed: {subject == issuer}", flush=True)
            except Exception as e:
                print(f"⚠️ [DEBUG] Failed to parse cert {i+1}: {e}", flush=True)
    except ImportError:
        print(f"⚠️ [DEBUG] cryptography module not available for cert inspection", flush=True)
    
    return certs

def apply_proxy_certs(domain="google.com", port=443):
    print(f"🔍 [DEBUG] Starting apply_proxy_certs for {domain}:{port}", flush=True)
    
    certs = get_proxy_certs(domain, port)
    
    if not certs:
        print("⚠️ No proxy certs found, using default certifi bundle", flush=True)
        print(f"🔍 [DEBUG] Default certifi bundle: {certifi.where()}", flush=True)
        return

    # Check if root CA is missing and add our known root CA
    try:
        from cryptography import x509
        from cryptography.hazmat.backends import default_backend
        import os
        
        last_cert = x509.load_pem_x509_certificate(certs[-1].encode('utf-8'), default_backend())
        last_subject = last_cert.subject.rfc4514_string()
        last_issuer = last_cert.issuer.rfc4514_string()
        
        if last_subject != last_issuer:
            print(f"🔍 [DEBUG] Chain incomplete - last cert is not self-signed", flush=True)
            print(f"🔍 [DEBUG] Last cert issuer: {last_issuer}", flush=True)
            
            # Add embedded root CA
            certs.append(ROOT_CA_CERT)
            print(f"✅ [DEBUG] Added embedded root CA", flush=True)
    except Exception as e:
        print(f"⚠️ [DEBUG] Could not check/add root CA: {e}", flush=True)
        import traceback
        traceback.print_exc()

    print(f"🔍 [DEBUG] Creating combined CA bundle...", flush=True)
    combined = tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".pem",
        prefix="ca_bundle_",
        delete=False
    )

    # base CA bundle
    certifi_path = certifi.where()
    print(f"🔍 [DEBUG] Reading base CA bundle from: {certifi_path}", flush=True)
    with open(certifi_path, "r") as f:
        base_content = f.read()
        combined.write(base_content)
        print(f"🔍 [DEBUG] Base CA bundle size: {len(base_content)} bytes", flush=True)

    # proxy certs - add in REVERSE order (root CA first, then intermediates, then leaf)
    # This ensures the trust chain is properly established
    print(f"🔍 [DEBUG] Adding {len(certs)} proxy certs to bundle (in reverse order)", flush=True)
    reversed_certs = list(reversed(certs))
    for i, cert in enumerate(reversed_certs):
        # Ensure each cert is properly formatted
        cert_clean = cert.strip()
        if not cert_clean.endswith('\n'):
            cert_clean += '\n'
        combined.write(cert_clean)
        print(f"🔍 [DEBUG] Added cert {i+1}/{len(certs)} ({len(cert_clean)} bytes) - was position {len(certs)-i} in chain", flush=True)

    combined.close()
    
    print(f"🔍 [DEBUG] Combined bundle written to: {combined.name}", flush=True)

    # Set environment variables
    os.environ["SSL_CERT_FILE"] = combined.name
    os.environ["REQUESTS_CA_BUNDLE"] = combined.name
    os.environ["CURL_CA_BUNDLE"] = combined.name
    os.environ["HTTPLIB2_CA_CERTS"] = combined.name
    os.environ["GRPC_DEFAULT_SSL_ROOTS_FILE_PATH"] = combined.name
    
    # Also set a global flag for easy access
    global _CERT_LOADED, _CERT_BUNDLE_PATH
    _CERT_LOADED = True
    _CERT_BUNDLE_PATH = combined.name

    print(f"✅ Custom CA bundle applied: {combined.name}", flush=True)
    print(f"🔍 [DEBUG] Environment variables set:", flush=True)
    print(f"   SSL_CERT_FILE={os.environ.get('SSL_CERT_FILE')}", flush=True)
    print(f"   REQUESTS_CA_BUNDLE={os.environ.get('REQUESTS_CA_BUNDLE')}", flush=True)


# apply once at import time
print(f"🔍 [DEBUG] proxy_cert_setup module imported", flush=True)
try:
    apply_proxy_certs("google.com", 443)
    print(f"🔍 [DEBUG] proxy_cert_setup completed successfully", flush=True)
except Exception as e:
    print(f"⚠️ Failed to apply proxy certs: {e}", flush=True)
    import traceback
    traceback.print_exc()
PYEOF
        ;;

    # -----------------------------------------------------------------------

    # -----------------------------------------------------------------------
    python3.13)
        cat <<'PY313EOF'
"""
proxy_cert_setup.py — Proxy CA cert helper for Python 3.13+ cloud functions.

USAGE
-----
Copy this file into your project and import it as the FIRST line of your
entry point, before any other import that may open a TLS connection:

    import proxy_cert_setup          # must be first

    import requests
    import functions_framework

    @functions_framework.http
    def handle(request):
        resp = requests.get("https://example.com", timeout=10)
        return resp.text

The module calls apply_proxy_certs() on import and sets:
  SSL_CERT_FILE, REQUESTS_CA_BUNDLE, CURL_CA_BUNDLE,
  HTTPLIB2_CA_CERTS, GRPC_DEFAULT_SSL_ROOTS_FILE_PATH

NOTE: This version uses Python 3.13+ features (get_verified_chain/get_unverified_chain).
      For Python 3.12, use --cloud-func python3.12 instead.
"""

import ssl
import socket
import tempfile
import os
import certifi

# Embedded root CA certificate for proxy
ROOT_CA_CERT = """-----BEGIN CERTIFICATE-----
MIIDkjCCAnqgAwIBAgIQYh7PD8WR0TDUDVENFkFmfDANBgkqhkiG9w0BAQsFADBP
MQswCQYDVQQGEwJVUzEfMB0GA1UEChMWQmx1ZUNvYXQgU3lzdGVtcywgSW5jLjEf
MB0GA1UEAxMWQ2xvdWQgU2VydmljZXMgUm9vdCBDQTAeFw0xMTA5MDYwMDAwMDBa
Fw0zNjA5MDUyMzU5NTlaME8xCzAJBgNVBAYTAlVTMR8wHQYDVQQKExZCbHVlQ29h
dCBTeXN0ZW1zLCBJbmMuMR8wHQYDVQQDExZDbG91ZCBTZXJ2aWNlcyBSb290IENB
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxAB79qIpN0NApUS0be0N
FYDqnY3g9jJsYZ6HVRsbw2eJnO2BKYhoBOW5fmUc9FaT0VbhIokHFRj4w3c2keWV
gTlFHbp6EZaaK1H8yczTf57WlXILuCrJ9eGYsWE2doJePnFpT1QejDRQYMKTjAfQ
A0twCBSxxmZ5TzEJ/xAu4cYTc3CnMrgA3n+/tcH7Yn5PDNGAiwZMWf5OPbktH33b
2r7yex+bgXXivY1Mw6k82RYLTLRsa8AoluBDTplqMbHo1QE7AuveeFkLL5GXX/8U
xao0mBvud2NJCHTZ9EcyHn5/Y2gnqJW4tmbMNXrrhAE+5Y1dWMAU8QFSF0aszQQE
2wIDAQABo2owaDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAmBgNV
HREEHzAdpBswGTEXMBUGA1UEAxMOTVBLSS0yMDQ4LTEtOTkwHQYDVR0OBBYEFKZK
F9G8WLV3JRaSK9JMlSPPKBQ2MA0GCSqGSIb3DQEBCwUAA4IBAQCJszHQDBq6Flgo
NRcgmgfn8LvyT1kWmBvM5UdZbPJwquKt4eqz67lXKzEnIUcWwdnJnkt0gmzXLw0z
N5jwISiDbV5iGuJp6x+ftwwvHf9WxqM/aF9xQ9V5767GP4HCz0XfVcx0A1h+nJnh
2suSISN6rPFhIhC5r/hbmBzzs/mjj60wFACDoP13Q2U3D+Jwm3Gf+LjQNHfLfPcB
rJx9hKP8MJEDYPjHyLZTPd9keF3YfG5JevANWIK+4gzgbeVaLEV9/yXWRNEYxYhC
y1nLwUcano2K8mgWkbUHctv7xw/SGymDCIrDnkHBrHqQ59YEfXWBZlLR0gyY56S1
X7G8bD+o
-----END CERTIFICATE-----
"""

def get_proxy_certs(domain="google.com", port=443):
    """Fetch the full certificate chain using pure Python SSL."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    certs = []
    with socket.create_connection((domain, port)) as sock:
        with ctx.wrap_socket(sock, server_hostname=domain) as ssock:
            for der_cert in ssock.get_verified_chain() or ssock.get_unverified_chain():
                pem = ssl.DER_cert_to_PEM_cert(der_cert)
                certs.append(pem)
    return certs


def apply_proxy_certs(domain="google.com", port=443):
    """Fetch proxy certs and create a combined CA bundle."""
    certs = get_proxy_certs(domain, port)
    if not certs:
        return

    # Check if root CA is missing and add it
    try:
        from cryptography import x509
        from cryptography.hazmat.backends import default_backend
        
        last_cert = x509.load_pem_x509_certificate(certs[-1].encode('utf-8'), default_backend())
        last_subject = last_cert.subject.rfc4514_string()
        last_issuer = last_cert.issuer.rfc4514_string()
        
        if last_subject != last_issuer:
            certs.append(ROOT_CA_CERT)
    except ImportError:
        pass

    combined = tempfile.NamedTemporaryFile(
        mode="w", suffix=".pem", prefix="ca_bundle_", delete=False
    )
    with open(certifi.where()) as f:
        combined.write(f.read())
    for cert in certs:
        combined.write(cert)
    combined.close()

    os.environ["SSL_CERT_FILE"] = combined.name
    os.environ["REQUESTS_CA_BUNDLE"] = combined.name
    os.environ["CURL_CA_BUNDLE"] = combined.name
    os.environ["HTTPLIB2_CA_CERTS"] = combined.name
    os.environ["GRPC_DEFAULT_SSL_ROOTS_FILE_PATH"] = combined.name

    return combined.name


_bundle = apply_proxy_certs()
PY313EOF
        ;;
    nodejs)
        cat <<'JSEOF'
/**
 * proxyCertSetup.js — Proxy CA cert helper for Node.js cloud functions.
 *
 * USAGE
 * -----
 * Copy this file into your project. Require it at the top of your entry
 * point and await the exported promise before making any HTTPS calls:
 *
 *   const certSetup = require('./proxyCertSetup');
 *   const https = require('https');
 *
 *   async function handle(req, res) {
 *     await certSetup;   // wait for certs to be applied
 *     https.get('https://example.com', (r) => {
 *       let data = '';
 *       r.on('data', c => data += c);
 *       r.on('end', () => res.send(data));
 *     });
 *   }
 *
 * The module also replaces https.globalAgent with one that trusts the
 * proxy CA, so standard https calls work without extra config.
 */

const tls = require('tls');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');

// Embedded root CA certificate for proxy
const ROOT_CA_CERT = `-----BEGIN CERTIFICATE-----
MIIDkjCCAnqgAwIBAgIQYh7PD8WR0TDUDVENFkFmfDANBgkqhkiG9w0BAQsFADBP
MQswCQYDVQQGEwJVUzEfMB0GA1UEChMWQmx1ZUNvYXQgU3lzdGVtcywgSW5jLjEf
MB0GA1UEAxMWQ2xvdWQgU2VydmljZXMgUm9vdCBDQTAeFw0xMTA5MDYwMDAwMDBa
Fw0zNjA5MDUyMzU5NTlaME8xCzAJBgNVBAYTAlVTMR8wHQYDVQQKExZCbHVlQ29h
dCBTeXN0ZW1zLCBJbmMuMR8wHQYDVQQDExZDbG91ZCBTZXJ2aWNlcyBSb290IENB
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxAB79qIpN0NApUS0be0N
FYDqnY3g9jJsYZ6HVRsbw2eJnO2BKYhoBOW5fmUc9FaT0VbhIokHFRj4w3c2keWV
gTlFHbp6EZaaK1H8yczTf57WlXILuCrJ9eGYsWE2doJePnFpT1QejDRQYMKTjAfQ
A0twCBSxxmZ5TzEJ/xAu4cYTc3CnMrgA3n+/tcH7Yn5PDNGAiwZMWf5OPbktH33b
2r7yex+bgXXivY1Mw6k82RYLTLRsa8AoluBDTplqMbHo1QE7AuveeFkLL5GXX/8U
xao0mBvud2NJCHTZ9EcyHn5/Y2gnqJW4tmbMNXrrhAE+5Y1dWMAU8QFSF0aszQQE
2wIDAQABo2owaDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAmBgNV
HREEHzAdpBswGTEXMBUGA1UEAxMOTVBLSS0yMDQ4LTEtOTkwHQYDVR0OBBYEFKZK
F9G8WLV3JRaSK9JMlSPPKBQ2MA0GCSqGSIb3DQEBCwUAA4IBAQCJszHQDBq6Flgo
NRcgmgfn8LvyT1kWmBvM5UdZbPJwquKt4eqz67lXKzEnIUcWwdnJnkt0gmzXLw0z
N5jwISiDbV5iGuJp6x+ftwwvHf9WxqM/aF9xQ9V5767GP4HCz0XfVcx0A1h+nJnh
2suSISN6rPFhIhC5r/hbmBzzs/mjj60wFACDoP13Q2U3D+Jwm3Gf+LjQNHfLfPcB
rJx9hKP8MJEDYPjHyLZTPd9keF3YfG5JevANWIK+4gzgbeVaLEV9/yXWRNEYxYhC
y1nLwUcano2K8mgWkbUHctv7xw/SGymDCIrDnkHBrHqQ59YEfXWBZlLR0gyY56S1
X7G8bD+o
-----END CERTIFICATE-----`;

function getProxyCertsSync(domain = 'google.com', port = 443) {
  try {
    const sock = tls.connect(port, domain, { servername: domain, rejectUnauthorized: false });
    const certs = [];
    return new Promise((resolve) => {
      sock.on('secureConnect', () => {
        let cert = sock.getPeerCertificate(true);
        const seen = new Set();
        while (cert && !seen.has(cert.fingerprint256)) {
          seen.add(cert.fingerprint256);
          const b64 = cert.raw.toString('base64');
          certs.push(`-----BEGIN CERTIFICATE-----\n${b64.match(/.{1,64}/g).join('\n')}\n-----END CERTIFICATE-----\n`);
          cert = cert.issuerCertificate;
        }
        sock.destroy();
        resolve(certs);
      });
      sock.on('error', () => resolve([]));
    });
  } catch {
    return Promise.resolve([]);
  }
}

async function applyProxyCerts(domain = 'google.com', port = 443) {
  const certs = await getProxyCertsSync(domain, port);
  if (!certs.length) return;

  // Check if root CA missing, add it
  if (certs.length > 0) {
    try {
      const lastCert = new crypto.X509Certificate(certs[certs.length - 1]);
      if (lastCert.subject !== lastCert.issuer) {
        certs.push(ROOT_CA_CERT);
      }
    } catch (e) {
      // Ignore parse errors
    }
  }

  const systemBundle = '/etc/ssl/certs/ca-certificates.crt';
  let existing = '';
  try { existing = fs.readFileSync(systemBundle, 'utf8'); } catch {}

  const combined = path.join(os.tmpdir(), 'ca_bundle_combined.pem');
  fs.writeFileSync(combined, existing + '\n' + certs.join('\n'));

  process.env.SSL_CERT_FILE = combined;
  process.env.GRPC_DEFAULT_SSL_ROOTS_FILE_PATH = combined;
  process.env.__PROXY_BUNDLE = combined;

  const proxyCertsParsed = certs.map(pem => new crypto.X509Certificate(pem));

  const agent = new https.Agent({
    rejectUnauthorized: false,
    checkServerIdentity: (hostname, peerCert) => {
      const err = tls.checkServerIdentity(hostname, peerCert);
      if (err) return err;
      let cert = peerCert;
      const seen = new Set();
      while (cert && !seen.has(cert.fingerprint256)) {
        seen.add(cert.fingerprint256);
        for (const proxyCert of proxyCertsParsed) {
          if (cert.issuerCertificate &&
              cert.issuerCertificate.fingerprint256 === proxyCert.fingerprint256) {
            return undefined;
          }
          if (proxyCert.fingerprint256 === cert.fingerprint256) {
            return undefined;
          }
        }
        cert = cert.issuerCertificate;
      }
      return undefined;
    }
  });

  https.globalAgent = agent;
  return combined;
}

module.exports = applyProxyCerts();
JSEOF
        ;;

    # -----------------------------------------------------------------------
    go)
        cat <<'GOEOF'
// proxycerts.go — Proxy CA cert helper for Go cloud functions.
//
// USAGE
// -----
// Place this file in a subdirectory called proxycerts/ inside your module,
// then call proxycerts.Apply() in your init() function before registering
// your handler:
//
//   package function
//
//   import (
//       "fmt"
//       "net/http"
//       "example.com/yourmodule/proxycerts"
//   )
//
//   func init() {
//       if _, err := proxycerts.Apply(); err != nil {
//           fmt.Printf("proxy cert setup error: %v\n", err)
//       }
//       // register your handler here
//   }
//
//   func handle(w http.ResponseWriter, r *http.Request) {
//       resp, _ := http.Get("https://example.com")
//       // handle resp ...
//   }
//
// If you need a custom http.Client that explicitly trusts the proxy CA,
// use proxycerts.OverrideSystemPool() to get an *x509.CertPool and pass
// it to your tls.Config.

package proxycerts

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
)

// Embedded root CA certificate for proxy
const ROOT_CA_CERT = `-----BEGIN CERTIFICATE-----
MIIDkjCCAnqgAwIBAgIQYh7PD8WR0TDUDVENFkFmfDANBgkqhkiG9w0BAQsFADBP
MQswCQYDVQQGEwJVUzEfMB0GA1UEChMWQmx1ZUNvYXQgU3lzdGVtcywgSW5jLjEf
MB0GA1UEAxMWQ2xvdWQgU2VydmljZXMgUm9vdCBDQTAeFw0xMTA5MDYwMDAwMDBa
Fw0zNjA5MDUyMzU5NTlaME8xCzAJBgNVBAYTAlVTMR8wHQYDVQQKExZCbHVlQ29h
dCBTeXN0ZW1zLCBJbmMuMR8wHQYDVQQDExZDbG91ZCBTZXJ2aWNlcyBSb290IENB
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxAB79qIpN0NApUS0be0N
FYDqnY3g9jJsYZ6HVRsbw2eJnO2BKYhoBOW5fmUc9FaT0VbhIokHFRj4w3c2keWV
gTlFHbp6EZaaK1H8yczTf57WlXILuCrJ9eGYsWE2doJePnFpT1QejDRQYMKTjAfQ
A0twCBSxxmZ5TzEJ/xAu4cYTc3CnMrgA3n+/tcH7Yn5PDNGAiwZMWf5OPbktH33b
2r7yex+bgXXivY1Mw6k82RYLTLRsa8AoluBDTplqMbHo1QE7AuveeFkLL5GXX/8U
xao0mBvud2NJCHTZ9EcyHn5/Y2gnqJW4tmbMNXrrhAE+5Y1dWMAU8QFSF0aszQQE
2wIDAQABo2owaDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAmBgNV
HREEHzAdpBswGTEXMBUGA1UEAxMOTVBLSS0yMDQ4LTEtOTkwHQYDVR0OBBYEFKZK
F9G8WLV3JRaSK9JMlSPPKBQ2MA0GCSqGSIb3DQEBCwUAA4IBAQCJszHQDBq6Flgo
NRcgmgfn8LvyT1kWmBvM5UdZbPJwquKt4eqz67lXKzEnIUcWwdnJnkt0gmzXLw0z
N5jwISiDbV5iGuJp6x+ftwwvHf9WxqM/aF9xQ9V5767GP4HCz0XfVcx0A1h+nJnh
2suSISN6rPFhIhC5r/hbmBzzs/mjj60wFACDoP13Q2U3D+Jwm3Gf+LjQNHfLfPcB
rJx9hKP8MJEDYPjHyLZTPd9keF3YfG5JevANWIK+4gzgbeVaLEV9/yXWRNEYxYhC
y1nLwUcano2K8mgWkbUHctv7xw/SGymDCIrDnkHBrHqQ59YEfXWBZlLR0gyY56S1
X7G8bD+o
-----END CERTIFICATE-----`

func getProxyCerts(domain string, port int) ([][]byte, error) {
	addr := fmt.Sprintf("%s:%d", domain, port)
	conn, err := tls.Dial("tcp", addr, &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	var certs [][]byte
	for _, cert := range conn.ConnectionState().PeerCertificates {
		block := &pem.Block{Type: "CERTIFICATE", Bytes: cert.Raw}
		certs = append(certs, pem.EncodeToMemory(block))
	}
	return certs, nil
}

// Apply fetches proxy certs, writes a combined PEM bundle to /tmp, and sets
// SSL_CERT_FILE and GRPC_DEFAULT_SSL_ROOTS_FILE_PATH. Returns the bundle path.
func Apply() (string, error) {
	certs, err := getProxyCerts("google.com", 443)
	if err != nil {
		return "", err
	}
	if len(certs) == 0 {
		return "", nil
	}

	// Check if root CA missing, add it
	if len(certs) > 0 {
		block, _ := pem.Decode(certs[len(certs)-1])
		if block != nil {
			lastCert, err := x509.ParseCertificate(block.Bytes)
			if err == nil && lastCert.Subject.String() != lastCert.Issuer.String() {
				certs = append(certs, []byte(ROOT_CA_CERT))
			}
		}
	}


	existing, _ := os.ReadFile("/etc/ssl/certs/ca-certificates.crt")
	combined := filepath.Join(os.TempDir(), "ca_bundle_combined.pem")
	f, err := os.Create(combined)
	if err != nil {
		return "", err
	}
	defer f.Close()
	f.Write(existing)
	for _, c := range certs {
		f.Write(c)
	}

	os.Setenv("SSL_CERT_FILE", combined)
	os.Setenv("GRPC_DEFAULT_SSL_ROOTS_FILE_PATH", combined)
	return combined, nil
}

// OverrideSystemPool returns the system cert pool augmented with proxy certs.
// Use this when building a custom tls.Config / http.Client.
func OverrideSystemPool() (*x509.CertPool, error) {
	pool, err := x509.SystemCertPool()
	if err != nil {
		pool = x509.NewCertPool()
	}
	certs, err := getProxyCerts("google.com", 443)
	if err != nil {
		return pool, err
	}
	for _, c := range certs {
		pool.AppendCertsFromPEM(c)
	}
	return pool, nil
}
GOEOF
        ;;

    # -----------------------------------------------------------------------
    java)
        cat <<'JAVAEOF'
// ProxyCertSetup.java — Proxy CA cert helper for Java cloud functions.
//
// USAGE
// -----
// Copy this file into your project (adjust the package declaration).
// Call ProxyCertSetup.apply() in a static block before any HTTPS activity:
//
//   import com.example.certs.ProxyCertSetup;
//   import java.net.http.HttpClient;
//   import java.net.http.HttpRequest;
//   import java.net.URI;
//
//   public class MyFunction implements HttpFunction {
//
//       static {
//           try {
//               ProxyCertSetup.apply();   // sets javax.net.ssl.trustStore
//           } catch (Exception e) {
//               System.err.println("Cert setup failed: " + e.getMessage());
//           }
//       }
//
//       @Override
//       public void service(HttpRequest request, HttpResponse response) throws Exception {
//           var client = HttpClient.newHttpClient();
//           var req = java.net.http.HttpRequest.newBuilder()
//                   .uri(URI.create("https://example.com")).build();
//           var resp = client.send(req, java.net.http.HttpResponse.BodyHandlers.ofString());
//           response.getWriter().write(resp.body());
//       }
//   }

package com.example.certs;

import javax.net.ssl.*;
import java.io.*;
import java.nio.file.*;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;

public class ProxyCertSetup {

    private static final String ROOT_CA_CERT = "-----BEGIN CERTIFICATE-----\nMIIDkjCCAnqgAwIBAgIQYh7PD8WR0TDUDVENFkFmfDANBgkqhkiG9w0BAQsFADBP\nMQswCQYDVQQGEwJVUzEfMB0GA1UEChMWQmx1ZUNvYXQgU3lzdGVtcywgSW5jLjEf\nMB0GA1UEAxMWQ2xvdWQgU2VydmljZXMgUm9vdCBDQTAeFw0xMTA5MDYwMDAwMDBa\nFw0zNjA5MDUyMzU5NTlaME8xCzAJBgNVBAYTAlVTMR8wHQYDVQQKExZCbHVlQ29h\ndCBTeXN0ZW1zLCBJbmMuMR8wHQYDVQQDExZDbG91ZCBTZXJ2aWNlcyBSb290IENB\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxAB79qIpN0NApUS0be0N\nFYDqnY3g9jJsYZ6HVRsbw2eJnO2BKYhoBOW5fmUc9FaT0VbhIokHFRj4w3c2keWV\ngTlFHbp6EZaaK1H8yczTf57WlXILuCrJ9eGYsWE2doJePnFpT1QejDRQYMKTjAfQ\nA0twCBSxxmZ5TzEJ/xAu4cYTc3CnMrgA3n+/tcH7Yn5PDNGAiwZMWf5OPbktH33b\n2r7yex+bgXXivY1Mw6k82RYLTLRsa8AoluBDTplqMbHo1QE7AuveeFkLL5GXX/8U\nxao0mBvud2NJCHTZ9EcyHn5/Y2gnqJW4tmbMNXrrhAE+5Y1dWMAU8QFSF0aszQQE\n2wIDAQABo2owaDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAmBgNV\nHREEHzAdpBswGTEXMBUGA1UEAxMOTVBLSS0yMDQ4LTEtOTkwHQYDVR0OBBYEFKZK\nF9G8WLV3JRaSK9JMlSPPKBQ2MA0GCSqGSIb3DQEBCwUAA4IBAQCJszHQDBq6Flgo\nNRcgmgfn8LvyT1kWmBvM5UdZbPJwquKt4eqz67lXKzEnIUcWwdnJnkt0gmzXLw0z\nN5jwISiDbV5iGuJp6x+ftwwvHf9WxqM/aF9xQ9V5767GP4HCz0XfVcx0A1h+nJnh\n2suSISN6rPFhIhC5r/hbmBzzs/mjj60wFACDoP13Q2U3D+Jwm3Gf+LjQNHfLfPcB\nrJx9hKP8MJEDYPjHyLZTPd9keF3YfG5JevANWIK+4gzgbeVaLEV9/yXWRNEYxYhC\ny1nLwUcano2K8mgWkbUHctv7xw/SGymDCIrDnkHBrHqQ59YEfXWBZlLR0gyY56S1\nX7G8bD+o\n-----END CERTIFICATE-----";

    public static String apply() throws Exception {
        return apply("google.com", 443);
    }

    public static String apply(String domain, int port) throws Exception {
        Certificate[] chain = getProxyCerts(domain, port);
        if (chain == null || chain.length == 0) return null;

        // Check if root CA missing, add it
        if (chain != null && chain.length > 0) {
            try {
                X509Certificate lastCert = (X509Certificate) chain[chain.length - 1];
                if (!lastCert.getSubjectDN().equals(lastCert.getIssuerDN())) {
                    java.io.ByteArrayInputStream bis = new java.io.ByteArrayInputStream(ROOT_CA_CERT.getBytes());
                    java.security.cert.CertificateFactory cf = java.security.cert.CertificateFactory.getInstance("X.509");
                    X509Certificate rootCert = (X509Certificate) cf.generateCertificate(bis);
                    Certificate[] newChain = new Certificate[chain.length + 1];
                    System.arraycopy(chain, 0, newChain, 0, chain.length);
                    newChain[chain.length] = rootCert;
                    chain = newChain;
                }
            } catch (Exception e) {
                // Ignore
            }
        }

        KeyStore ts = KeyStore.getInstance(KeyStore.getDefaultType());
        Path defaultTs = Path.of(System.getProperty("java.home"), "lib", "security", "cacerts");
        try (InputStream is = Files.newInputStream(defaultTs)) {
            ts.load(is, "changeit".toCharArray());
        }

        for (int i = 0; i < chain.length; i++) {
            ts.setCertificateEntry("proxy-cert-" + i, chain[i]);
        }

        Path combined = Files.createTempFile("ca_bundle_", ".jks");
        try (OutputStream os = Files.newOutputStream(combined)) {
            ts.store(os, "changeit".toCharArray());
        }

        System.setProperty("javax.net.ssl.trustStore", combined.toString());
        System.setProperty("javax.net.ssl.trustStorePassword", "changeit");

        Path pemFile = Files.createTempFile("ca_bundle_", ".pem");
        StringBuilder pem = new StringBuilder();
        try { pem.append(Files.readString(Path.of("/etc/ssl/certs/ca-certificates.crt"))); } catch (Exception ignored) {}
        for (Certificate cert : chain) {
            pem.append("-----BEGIN CERTIFICATE-----\n");
            pem.append(java.util.Base64.getMimeEncoder(64, "\n".getBytes()).encodeToString(cert.getEncoded()));
            pem.append("\n-----END CERTIFICATE-----\n");
        }
        Files.writeString(pemFile, pem.toString());
        System.setProperty("GRPC_DEFAULT_SSL_ROOTS_FILE_PATH", pemFile.toString());

        return combined.toString();
    }

    private static Certificate[] getProxyCerts(String domain, int port) throws Exception {
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(null, new TrustManager[]{new X509TrustManager() {
            public void checkClientTrusted(X509Certificate[] c, String t) {}
            public void checkServerTrusted(X509Certificate[] c, String t) {}
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        }}, null);

        SSLSocketFactory sf = ctx.getSocketFactory();
        try (SSLSocket sock = (SSLSocket) sf.createSocket(domain, port)) {
            sock.startHandshake();
            return sock.getSession().getPeerCertificates();
        }
    }
}
JAVAEOF
        ;;

    # -----------------------------------------------------------------------
    dotnet)
        cat <<'CSEOF'
// ProxyCertSetup.cs — Proxy CA cert helper for .NET cloud functions.
//
// USAGE
// -----
// Copy this file into your project. Use ProxyCertSetup.HttpClient for all
// outbound HTTPS calls — it is pre-configured to trust the proxy CA.
// The static constructor runs Apply() automatically on first access.
//
//   public class MyFunction : IHttpFunction
//   {
//       public async Task HandleAsync(HttpContext context)
//       {
//           // ProxyCertSetup.HttpClient already trusts the proxy CA
//           var body = await ProxyCertSetup.HttpClient.GetStringAsync("https://example.com");
//           await context.Response.WriteAsync(body);
//       }
//   }

using System;
using System.IO;
using System.Net.Http;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;

public static class ProxyCertSetup
{
    private static X509Certificate2Collection _proxyCerts;

    private const string ROOT_CA_CERT = @"-----BEGIN CERTIFICATE-----
MIIDkjCCAnqgAwIBAgIQYh7PD8WR0TDUDVENFkFmfDANBgkqhkiG9w0BAQsFADBP
MQswCQYDVQQGEwJVUzEfMB0GA1UEChMWQmx1ZUNvYXQgU3lzdGVtcywgSW5jLjEf
MB0GA1UEAxMWQ2xvdWQgU2VydmljZXMgUm9vdCBDQTAeFw0xMTA5MDYwMDAwMDBa
Fw0zNjA5MDUyMzU5NTlaME8xCzAJBgNVBAYTAlVTMR8wHQYDVQQKExZCbHVlQ29h
dCBTeXN0ZW1zLCBJbmMuMR8wHQYDVQQDExZDbG91ZCBTZXJ2aWNlcyBSb290IENB
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxAB79qIpN0NApUS0be0N
FYDqnY3g9jJsYZ6HVRsbw2eJnO2BKYhoBOW5fmUc9FaT0VbhIokHFRj4w3c2keWV
gTlFHbp6EZaaK1H8yczTf57WlXILuCrJ9eGYsWE2doJePnFpT1QejDRQYMKTjAfQ
A0twCBSxxmZ5TzEJ/xAu4cYTc3CnMrgA3n+/tcH7Yn5PDNGAiwZMWf5OPbktH33b
2r7yex+bgXXivY1Mw6k82RYLTLRsa8AoluBDTplqMbHo1QE7AuveeFkLL5GXX/8U
xao0mBvud2NJCHTZ9EcyHn5/Y2gnqJW4tmbMNXrrhAE+5Y1dWMAU8QFSF0aszQQE
2wIDAQABo2owaDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAmBgNV
HREEHzAdpBswGTEXMBUGA1UEAxMOTVBLSS0yMDQ4LTEtOTkwHQYDVR0OBBYEFKZK
F9G8WLV3JRaSK9JMlSPPKBQ2MA0GCSqGSIb3DQEBCwUAA4IBAQCJszHQDBq6Flgo
NRcgmgfn8LvyT1kWmBvM5UdZbPJwquKt4eqz67lXKzEnIUcWwdnJnkt0gmzXLw0z
N5jwISiDbV5iGuJp6x+ftwwvHf9WxqM/aF9xQ9V5767GP4HCz0XfVcx0A1h+nJnh
2suSISN6rPFhIhC5r/hbmBzzs/mjj60wFACDoP13Q2U3D+Jwm3Gf+LjQNHfLfPcB
rJx9hKP8MJEDYPjHyLZTPd9keF3YfG5JevANWIK+4gzgbeVaLEV9/yXWRNEYxYhC
y1nLwUcano2K8mgWkbUHctv7xw/SGymDCIrDnkHBrHqQ59YEfXWBZlLR0gyY56S1
X7G8bD+o
-----END CERTIFICATE-----";

    public static readonly HttpClient HttpClient;

    public static string Apply(string domain = "google.com", int port = 443)
    {
        _proxyCerts = GetProxyCerts(domain, port);
        if (_proxyCerts == null || _proxyCerts.Count == 0) return null;

        // Check if root CA missing, add it
        if (_proxyCerts != null && _proxyCerts.Count > 0)
        {
            try
            {
                var lastCert = _proxyCerts[_proxyCerts.Count - 1];
                if (lastCert.Subject != lastCert.Issuer)
                {
                    _proxyCerts.Add(new X509Certificate2(System.Text.Encoding.UTF8.GetBytes(ROOT_CA_CERT)));
                }
            }
            catch
            {
                // Ignore
            }
        }

        var sb = new StringBuilder();
        try { sb.Append(File.ReadAllText("/etc/ssl/certs/ca-certificates.crt")); } catch { }
        foreach (var cert in _proxyCerts)
        {
            sb.AppendLine("-----BEGIN CERTIFICATE-----");
            sb.AppendLine(Convert.ToBase64String(cert.RawData, Base64FormattingOptions.InsertLineBreaks));
            sb.AppendLine("-----END CERTIFICATE-----");
        }
        string combined = Path.Combine(Path.GetTempPath(), "ca_bundle_combined.pem");
        File.WriteAllText(combined, sb.ToString());
        Environment.SetEnvironmentVariable("SSL_CERT_FILE", combined);
        Environment.SetEnvironmentVariable("GRPC_DEFAULT_SSL_ROOTS_FILE_PATH", combined);
        return combined;
    }

    static ProxyCertSetup()
    {
        Apply();
        if (_proxyCerts != null && _proxyCerts.Count > 0)
        {
            var handler = new SocketsHttpHandler
            {
                SslOptions = new SslClientAuthenticationOptions
                {
                    RemoteCertificateValidationCallback = ValidateWithProxyCerts
                }
            };
            HttpClient = new HttpClient(handler);
        }
        else
        {
            HttpClient = new HttpClient();
        }
    }

    private static bool ValidateWithProxyCerts(object sender, X509Certificate certificate,
        X509Chain chain, SslPolicyErrors errors)
    {
        if (errors == SslPolicyErrors.None) return true;
        if (_proxyCerts == null) return false;

        using var chain2 = new X509Chain();
        chain2.ChainPolicy.ExtraStore.AddRange(_proxyCerts);
        chain2.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
        return chain2.Build(new X509Certificate2(certificate));
    }

    private static X509Certificate2Collection GetProxyCerts(string domain, int port)
    {
        var certs = new X509Certificate2Collection();
        using var tcp = new TcpClient(domain, port);
        using var ssl = new SslStream(tcp.GetStream(), false,
            (sender, cert, chain, errors) =>
            {
                if (chain != null)
                    foreach (var el in chain.ChainElements)
                        certs.Add(new X509Certificate2(el.Certificate.RawData));
                return true;
            });
        ssl.AuthenticateAsClient(domain);
        return certs;
    }
}
CSEOF
        ;;

    # -----------------------------------------------------------------------
    php)
        cat <<'PHPEOF'
# ===========================================================================
# FILE: proxy_cert_setup.php
# ===========================================================================
<?php
/**
 * proxy_cert_setup.php — Proxy CA cert helper for PHP cloud functions.
 *
 * USAGE
 * -----
 * 1. Copy this file into your project.
 * 2. Create a php.ini in your project root (see below). This is REQUIRED —
 *    it tells PHP's SSL stack where to find the bundle before any code runs.
 * 3. require_once this file at the top of your entry point:
 *
 *      <?php
 *      require_once __DIR__ . '/proxy_cert_setup.php';
 *      // $_proxyBundle is now set to /tmp/ca_bundle_combined.pem
 *
 *      $ch = curl_init('https://example.com');
 *      curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
 *      $body = curl_exec($ch);
 *      curl_close($ch);
 *      echo $body;
 *
 * NOTE: php.ini and proxy_cert_setup.php both use the fixed path
 * /tmp/ca_bundle_combined.pem — they are coupled by design.
 */

const ROOT_CA_CERT = <<<'CERT'
-----BEGIN CERTIFICATE-----
MIIDkjCCAnqgAwIBAgIQYh7PD8WR0TDUDVENFkFmfDANBgkqhkiG9w0BAQsFADBP
MQswCQYDVQQGEwJVUzEfMB0GA1UEChMWQmx1ZUNvYXQgU3lzdGVtcywgSW5jLjEf
MB0GA1UEAxMWQ2xvdWQgU2VydmljZXMgUm9vdCBDQTAeFw0xMTA5MDYwMDAwMDBa
Fw0zNjA5MDUyMzU5NTlaME8xCzAJBgNVBAYTAlVTMR8wHQYDVQQKExZCbHVlQ29h
dCBTeXN0ZW1zLCBJbmMuMR8wHQYDVQQDExZDbG91ZCBTZXJ2aWNlcyBSb290IENB
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxAB79qIpN0NApUS0be0N
FYDqnY3g9jJsYZ6HVRsbw2eJnO2BKYhoBOW5fmUc9FaT0VbhIokHFRj4w3c2keWV
gTlFHbp6EZaaK1H8yczTf57WlXILuCrJ9eGYsWE2doJePnFpT1QejDRQYMKTjAfQ
A0twCBSxxmZ5TzEJ/xAu4cYTc3CnMrgA3n+/tcH7Yn5PDNGAiwZMWf5OPbktH33b
2r7yex+bgXXivY1Mw6k82RYLTLRsa8AoluBDTplqMbHo1QE7AuveeFkLL5GXX/8U
xao0mBvud2NJCHTZ9EcyHn5/Y2gnqJW4tmbMNXrrhAE+5Y1dWMAU8QFSF0aszQQE
2wIDAQABo2owaDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAmBgNV
HREEHzAdpBswGTEXMBUGA1UEAxMOTVBLSS0yMDQ4LTEtOTkwHQYDVR0OBBYEFKZK
F9G8WLV3JRaSK9JMlSPPKBQ2MA0GCSqGSIb3DQEBCwUAA4IBAQCJszHQDBq6Flgo
NRcgmgfn8LvyT1kWmBvM5UdZbPJwquKt4eqz67lXKzEnIUcWwdnJnkt0gmzXLw0z
N5jwISiDbV5iGuJp6x+ftwwvHf9WxqM/aF9xQ9V5767GP4HCz0XfVcx0A1h+nJnh
2suSISN6rPFhIhC5r/hbmBzzs/mjj60wFACDoP13Q2U3D+Jwm3Gf+LjQNHfLfPcB
rJx9hKP8MJEDYPjHyLZTPd9keF3YfG5JevANWIK+4gzgbeVaLEV9/yXWRNEYxYhC
y1nLwUcano2K8mgWkbUHctv7xw/SGymDCIrDnkHBrHqQ59YEfXWBZlLR0gyY56S1
X7G8bD+o
-----END CERTIFICATE-----
CERT;

function getProxyCerts(string $domain = 'google.com', int $port = 443): array
{
    $ctx = stream_context_create([
        'ssl' => [
            'capture_peer_cert_chain' => true,
            'verify_peer'             => false,
            'verify_peer_name'        => false,
        ],
    ]);

    $client = @stream_socket_client(
        "ssl://{$domain}:{$port}",
        $errno, $errstr, 10,
        STREAM_CLIENT_CONNECT, $ctx
    );
    if (!$client) return [];

    $params = stream_context_get_params($client);
    fclose($client);

    $certs = [];
    foreach ($params['options']['ssl']['peer_certificate_chain'] ?? [] as $cert) {
        openssl_x509_export($cert, $pem);
        $certs[] = $pem;
    }
    return $certs;
}

function applyProxyCerts(string $domain = 'google.com', int $port = 443): ?string
{
    $certs = getProxyCerts($domain, $port);
    if (empty($certs)) return null;

    // Check if root CA missing, add it
    if (!empty($certs)) {
        $lastCert = openssl_x509_read(end($certs));
        if ($lastCert) {
            $parsed = openssl_x509_parse($lastCert);
            if ($parsed['subject']['CN'] !== $parsed['issuer']['CN']) {
                $certs[] = ROOT_CA_CERT;
            }
        }
    }

    $systemBundle = '/etc/ssl/certs/ca-certificates.crt';
    $existing = is_readable($systemBundle) ? file_get_contents($systemBundle) : '';

    $combined = '/tmp/ca_bundle_combined.pem';
    file_put_contents($combined, $existing . "\n" . implode("\n", $certs));

    return $combined;
}

$_proxyBundle = applyProxyCerts();


# ===========================================================================
# FILE: php.ini
# ===========================================================================
; php.ini — Required companion to proxy_cert_setup.php
;
; Place this file in your project root (alongside your index.php).
; It points PHP's curl and openssl to the combined CA bundle that
; proxy_cert_setup.php writes at /tmp/ca_bundle_combined.pem.
; Without this file the bundle is ignored by PHP's SSL stack.

curl.cainfo    = /tmp/ca_bundle_combined.pem
openssl.cafile = /tmp/ca_bundle_combined.pem
PHPEOF
        ;;

    # -----------------------------------------------------------------------
    ruby)
        cat <<'RBEOF'
# proxy_cert_setup.rb — Proxy CA cert helper for Ruby cloud functions.
#
# USAGE
# -----
# Copy this file into your project. require_relative it before any
# Net::HTTP calls. The helper monkey-patches Net::HTTP so all SSL
# connections automatically use the proxy cert store — no per-request
# config needed.
#
#   require_relative 'proxy_cert_setup'
#   require 'net/http'
#   require 'uri'
#
#   uri  = URI('https://example.com')
#   http = Net::HTTP.new(uri.host, uri.port)
#   http.use_ssl = true   # proxy cert store applied automatically
#   resp = http.get(uri.path)
#   puts resp.body
#
# $proxy_bundle holds the path to the combined PEM file if you need it.

require 'socket'
require 'openssl'
require 'tempfile'
require 'net/http'

ROOT_CA_CERT = <<~CERT
-----BEGIN CERTIFICATE-----
MIIDkjCCAnqgAwIBAgIQYh7PD8WR0TDUDVENFkFmfDANBgkqhkiG9w0BAQsFADBP
MQswCQYDVQQGEwJVUzEfMB0GA1UEChMWQmx1ZUNvYXQgU3lzdGVtcywgSW5jLjEf
MB0GA1UEAxMWQ2xvdWQgU2VydmljZXMgUm9vdCBDQTAeFw0xMTA5MDYwMDAwMDBa
Fw0zNjA5MDUyMzU5NTlaME8xCzAJBgNVBAYTAlVTMR8wHQYDVQQKExZCbHVlQ29h
dCBTeXN0ZW1zLCBJbmMuMR8wHQYDVQQDExZDbG91ZCBTZXJ2aWNlcyBSb290IENB
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxAB79qIpN0NApUS0be0N
FYDqnY3g9jJsYZ6HVRsbw2eJnO2BKYhoBOW5fmUc9FaT0VbhIokHFRj4w3c2keWV
gTlFHbp6EZaaK1H8yczTf57WlXILuCrJ9eGYsWE2doJePnFpT1QejDRQYMKTjAfQ
A0twCBSxxmZ5TzEJ/xAu4cYTc3CnMrgA3n+/tcH7Yn5PDNGAiwZMWf5OPbktH33b
2r7yex+bgXXivY1Mw6k82RYLTLRsa8AoluBDTplqMbHo1QE7AuveeFkLL5GXX/8U
xao0mBvud2NJCHTZ9EcyHn5/Y2gnqJW4tmbMNXrrhAE+5Y1dWMAU8QFSF0aszQQE
2wIDAQABo2owaDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAmBgNV
HREEHzAdpBswGTEXMBUGA1UEAxMOTVBLSS0yMDQ4LTEtOTkwHQYDVR0OBBYEFKZK
F9G8WLV3JRaSK9JMlSPPKBQ2MA0GCSqGSIb3DQEBCwUAA4IBAQCJszHQDBq6Flgo
NRcgmgfn8LvyT1kWmBvM5UdZbPJwquKt4eqz67lXKzEnIUcWwdnJnkt0gmzXLw0z
N5jwISiDbV5iGuJp6x+ftwwvHf9WxqM/aF9xQ9V5767GP4HCz0XfVcx0A1h+nJnh
2suSISN6rPFhIhC5r/hbmBzzs/mjj60wFACDoP13Q2U3D+Jwm3Gf+LjQNHfLfPcB
rJx9hKP8MJEDYPjHyLZTPd9keF3YfG5JevANWIK+4gzgbeVaLEV9/yXWRNEYxYhC
y1nLwUcano2K8mgWkbUHctv7xw/SGymDCIrDnkHBrHqQ59YEfXWBZlLR0gyY56S1
X7G8bD+o
-----END CERTIFICATE-----
CERT

def get_proxy_certs(domain = 'google.com', port = 443)
  ctx = OpenSSL::SSL::SSLContext.new
  ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE

  tcp = TCPSocket.new(domain, port)
  ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
  ssl.hostname = domain
  ssl.connect

  certs = ssl.peer_cert_chain&.map(&:to_pem) || []
  ssl.close
  tcp.close
  certs
rescue
  []
end

def apply_proxy_certs(domain = 'google.com', port = 443)
  certs = get_proxy_certs(domain, port)
  return if certs.empty?

  # Check if root CA missing, add it
  unless certs.empty?
    last_cert = OpenSSL::X509::Certificate.new(certs.last)
    if last_cert.subject.to_s != last_cert.issuer.to_s
      certs << ROOT_CA_CERT
    end
  end

  system_bundle = '/etc/ssl/certs/ca-certificates.crt'
  existing = File.readable?(system_bundle) ? File.read(system_bundle) : ''

  combined = Tempfile.new(['ca_bundle_', '.pem'])
  combined.write(existing)
  combined.write("\n")
  certs.each { |c| combined.write(c) }
  combined.close

  ENV['SSL_CERT_FILE'] = combined.path
  ENV['GRPC_DEFAULT_SSL_ROOTS_FILE_PATH'] = combined.path

  store = OpenSSL::X509::Store.new
  store.set_default_paths
  certs.each { |pem| store.add_cert(OpenSSL::X509::Certificate.new(pem)) rescue nil }
  store.flags = OpenSSL::X509::V_FLAG_PARTIAL_CHAIN

  # Monkey-patch Net::HTTP to use our cert store transparently
  Net::HTTP.class_eval do
    original_use_ssl = instance_method(:use_ssl=)
    define_method(:use_ssl=) do |val|
      original_use_ssl.bind(self).call(val)
      self.cert_store = store if val
    end
  end

  combined.path
end

$proxy_bundle = apply_proxy_certs
RBEOF
        ;;

    *)
        echo "Unknown language: $lang" >&2
        echo "Supported: python, nodejs, go, java, dotnet, php, ruby" >&2
        exit 1
        ;;
    esac
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
    
    # Check if the last certificate in the chain is self-signed (root CA)
    # If not, append the BlueCoat Root CA
    local last_cert="${cert_files[-1]}"
    local subject
    local issuer
    subject=$(openssl x509 -in "$last_cert" -noout -subject 2>/dev/null | sed 's/^subject=//' || true)
    issuer=$(openssl x509 -in "$last_cert" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || true)
    
    if [[ -n "$subject" && -n "$issuer" && "$subject" != "$issuer" ]]; then
        log "Chain is incomplete (last cert is not self-signed), appending BlueCoat Root CA"
        echo "$ROOT_CA_CERT" >> "${domain}_ca_chain.pem"
    else
        log "Chain appears complete (last cert is self-signed)"
    fi
    
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


detect_python_venvs() {
    log "Detecting Python virtual environments in /home..."
    
    # Find venvs by looking for pyvenv.cfg
    local venv_count=0
    local venv_found=0
    
    # Search /home for venvs - with error handling
    local find_results
    find_results=$(find /home -maxdepth 5 -type f -name "pyvenv.cfg" 2>/dev/null || true)
    
    if [[ -z "$find_results" ]]; then
        log "No Python virtual environments found in /home"
        return 0
    fi
    
    local pyvenv_cfg
    local venv_path
    local python_exe
    local venv_certifi
    
    while IFS= read -r pyvenv_cfg; do
        [[ -z "$pyvenv_cfg" ]] && continue
        
        venv_path=$(dirname "$pyvenv_cfg" 2>/dev/null || echo "")
        [[ -z "$venv_path" ]] && continue
        
        venv_found=$((venv_found + 1))
        log "Checking venv: $venv_path"
        
        # Get the venv's python executable
        python_exe=""
        if [[ -x "${venv_path}/bin/python3" ]]; then
            python_exe="${venv_path}/bin/python3"
        elif [[ -x "${venv_path}/bin/python" ]]; then
            python_exe="${venv_path}/bin/python"
        else
            log "  No executable python found in venv"
            continue
        fi
        
        # Try to get certifi paths from venv's site-packages
        # This ensures pip install commands from the venv will work
        local found_any=false
        
        # Check for regular certifi package
        venv_certifi=$("$python_exe" -c "import certifi; print(certifi.where())" 2>/dev/null || true)
        if [[ -n "$venv_certifi" && -f "$venv_certifi" && "$venv_certifi" == "$venv_path"* ]]; then
            PYTHON_PATHS+=("$venv_certifi")
            log "  Found certifi: $venv_certifi"
            found_any=true
        fi
        
        # Check for pip's vendored certifi (used by pip install)
        local pip_certifi
        pip_certifi=$("$python_exe" -c "import pip._vendor.certifi as c; print(c.where())" 2>/dev/null || true)
        if [[ -n "$pip_certifi" && -f "$pip_certifi" ]]; then
            if [[ "$pip_certifi" == "$venv_path"* ]]; then
                # Avoid duplicates
                if [[ "$pip_certifi" != "$venv_certifi" ]]; then
                    PYTHON_PATHS+=("$pip_certifi")
                    log "  Found pip vendored certifi: $pip_certifi"
                    found_any=true
                fi
            fi
        fi
        
        # Also check for the actual file location in pip's vendor directory
        local pip_vendor_cert="${venv_path}/lib/python"*"/site-packages/pip/_vendor/certifi/cacert.pem"
        for cert_path in $pip_vendor_cert; do
            if [[ -f "$cert_path" ]]; then
                # Check if not already added
                local already_added=false
                for added_path in "${PYTHON_PATHS[@]}"; do
                    if [[ "$added_path" == "$cert_path" ]]; then
                        already_added=true
                        break
                    fi
                done
                if [[ "$already_added" == false ]]; then
                    PYTHON_PATHS+=("$cert_path")
                    log "  Found pip vendored certifi (direct): $cert_path"
                    found_any=true
                fi
            fi
        done
        
        if [[ "$found_any" == true ]]; then
            venv_count=$((venv_count + 1))
        else
            log "  No venv-specific certifi found (uses system certifi)"
        fi
    done <<< "$find_results"
    
    if [[ $venv_count -gt 0 ]]; then
        log "Found $venv_count Python virtual environment(s) with certifi"
    elif [[ $venv_found -gt 0 ]]; then
        log "Found $venv_found venv(s) but none have certifi installed"
    fi
    
    return 0
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
        # Skip if this is the ca_bundle itself (avoid appending to itself)
        if [[ "$cacert" == "$ca_bundle" ]]; then
            continue
        fi
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

install_java_ca() {
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
    local skip_venv=false
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
            --skip-venv)
                skip_venv=true
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
            --cloud-func)
                cloud_func_snippet "$2"
                ;;  # cloud_func_snippet exits, so we never reach here
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
    [[ "$skip_venv" == false ]] && { detect_python_venvs || true; }
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
