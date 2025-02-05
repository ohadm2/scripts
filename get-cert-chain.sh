#!/bin/bash

CERTS_LOCATION=/tmp

# Check if domain argument is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <domain>"
  echo "NOTE! WITHOUT schema (don't add http/https)!"
  exit 1
fi

# Set domain from command line argument
DOMAIN="$1"

VERIFY=3

# Get certificate chain using OpenSSL
#CERT_CHAIN=$(openssl s_client -showcerts -verify 5 "${DOMAIN}":443 </dev/null)
if [ -d "$CERTS_LOCATION" ]; then
  cd $CERTS_LOCATION
else
  SCRIPT_LOC=$(dirname $(readlink -f "${BASH_SOURCE:-$0}"))
  cd $SCRIPT_LOC
fi

CERTS=$(openssl s_client -showcerts -verify ${VERIFY} -connect ${DOMAIN}:443 2>/dev/null < /dev/null | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p')

i=0
NAME_COUNTER=1

CURRENT_CERT_NAME="cert_"$NAME_COUNTER".pem"

while read -r line; 
do
  if [[ $line == *"CERTIFICATE"* ]]; then
    i=$((i+1))
    
    if [[ $line == *"BEGIN"* ]]; then
      > $CURRENT_CERT_NAME
    fi
  fi
    
  echo $line >> $CURRENT_CERT_NAME

  if [ $i -gt 0 -a `expr $i % 2` -eq 0 ]; then
    echo "Certificate ('$CURRENT_CERT_NAME') info:"
    echo "------------------------------------------------------------------"
    openssl x509 -inform PEM -in $CURRENT_CERT_NAME -noout -issuer -subject
    echo
    echo
    
    NAME_COUNTER=$((NAME_COUNTER+1))
    CURRENT_CERT_NAME="cert_"$NAME_COUNTER".pem"
  fi

done <<< "$CERTS"

ls | grep "\.pem"


