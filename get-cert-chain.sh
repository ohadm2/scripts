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
CERT_NUM=0
TMPFILE="${DOMAIN}_tmp.pem"
CA_COUNTER=1

printf '%s\n' "$CERTS" | while IFS= read -r line; do
  case "$line" in
    *CERTIFICATE*)
      i=$((i + 1))
      case "$line" in
        *BEGIN*)
          : > "$TMPFILE"
          ;;
      esac
      ;;
  esac

  echo "$line" >> "$TMPFILE"

  # test even number of CERTIFICATE lines
  if [ "$i" -gt 0 ] && [ $(( i % 2 )) -eq 0 ]; then
    CERT_NUM=$((CERT_NUM + 1))

    # Skip the first cert (end-entity/leaf)
    if [ "$CERT_NUM" -eq 1 ]; then
      rm -f "$TMPFILE"
    else
      # Determine root vs intermediate
      ISSUER=$(openssl x509 -in "$TMPFILE" -noout -issuer 2>/dev/null)
      SUBJECT=$(openssl x509 -in "$TMPFILE" -noout -subject 2>/dev/null)
      if [ "$ISSUER" = "$(echo "$SUBJECT" | sed 's/^subject/issuer/')" ]; then
        CA_TYPE="root"
      else
        CA_TYPE="intermediate"
      fi

      FINAL_NAME="${DOMAIN}_${CA_TYPE}_${CA_COUNTER}.pem"
      mv "$TMPFILE" "$FINAL_NAME"

      echo "CA Certificate ('$FINAL_NAME') [$CA_TYPE]:"
      echo "-------------------------------------------------------------------------------------------------"
      openssl x509 -inform PEM -in "$FINAL_NAME" -noout -issuer -subject -dates -serial -fingerprint
      echo
      CA_COUNTER=$((CA_COUNTER + 1))
    fi
  fi

done

echo
echo "Certs dir $(pwd):"
echo "------------------------"
ls | grep "\.pem"

