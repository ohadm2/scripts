#!/bin/sh

CERTS_LOCATION=/tmp

if [ -z "$1" ]; then
  echo "Usage: $0 domain"
  echo "NOTE! WITHOUT schema (don't add http/https)!"
  exit 1
fi

DOMAIN="$1"
VERIFY=5

if [ -d "$CERTS_LOCATION" ]; then
  cd "$CERTS_LOCATION"
else
  # Try to determine script location portably
  SCRIPT_PATH="$0"
  
  # If called with relative path, prepend PWD
  case "$SCRIPT_PATH" in
    /*) ;; # absolute path
    *) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;;
  esac

  SCRIPT_LOC=$(dirname "$SCRIPT_PATH")
  cd "$SCRIPT_LOC"
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR! openssl not found! Exiting ..."
  exit 1
fi

# Get the cert chain
CERTS=$(openssl s_client -showcerts -verify "$VERIFY" "${DOMAIN}":443 </dev/null 2>/dev/null | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p')

i=0
NAME_COUNTER=1
CURRENT_CERT_NAME="${DOMAIN}_${NAME_COUNTER}.pem"

printf '%s\n' "$CERTS" | while IFS= read -r line; do
  case "$line" in
    *CERTIFICATE*)
      i=$((i + 1))
      case "$line" in
        *BEGIN*)
          : > "$CURRENT_CERT_NAME"
          ;;
      esac
      ;;
  esac

  echo "$line" >> "$CURRENT_CERT_NAME"

  # test even number of CERTIFICATE lines
  if [ "$i" -gt 0 ] && [ $(( i % 2 )) -eq 0 ]; then
    echo "Certificate ('$CURRENT_CERT_NAME') info:"
    echo "-------------------------------------------------------------------------------------------------"
    openssl x509 -inform PEM -in "$CURRENT_CERT_NAME" -noout -issuer -subject -dates -serial -fingerprint
    echo
    NAME_COUNTER=$(( NAME_COUNTER + 1 ))
    CURRENT_CERT_NAME="${DOMAIN}_${NAME_COUNTER}.pem"
  fi

done

echo
echo "Certs dir $(pwd):"
echo "------------------------"
ls | grep "\.pem"

