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
CERT_NUM=0
CA_COUNTER=1
TMPFILE=$DOMAIN"_tmp.pem"

while read -r line; 
do
  if [[ $line == *"CERTIFICATE"* ]]; then
    i=$((i+1))
    
    if [[ $line == *"BEGIN"* ]]; then
      > $TMPFILE
    fi
  fi
    
  echo $line >> $TMPFILE

  if [ $i -gt 0 -a `expr $i % 2` -eq 0 ]; then
    CERT_NUM=$((CERT_NUM+1))

    # Skip the first cert (end-entity/leaf)
    if [ $CERT_NUM -eq 1 ]; then
      rm -f $TMPFILE
    else
      # Determine root vs intermediate
      ISSUER=$(openssl x509 -in $TMPFILE -noout -issuer 2>/dev/null)
      SUBJECT=$(openssl x509 -in $TMPFILE -noout -subject 2>/dev/null)
      if [[ "$ISSUER" == "$(echo "$SUBJECT" | sed 's/^subject/issuer/')" ]]; then
        CA_TYPE="root"
      else
        CA_TYPE="intermediate"
      fi

      FINAL_NAME="${DOMAIN}_${CA_TYPE}_${CA_COUNTER}.pem"
      mv $TMPFILE $FINAL_NAME

      echo "CA Certificate ('$FINAL_NAME') [$CA_TYPE]:"
      echo "-------------------------------------------------------------------------------------------------"
      openssl x509 -inform PEM -in $FINAL_NAME -noout -issuer -subject -dates -serial -fingerprint
      echo
      echo
      
      CA_COUNTER=$((CA_COUNTER+1))
    fi
  fi

done <<< "$CERTS"

echo
echo "Certs dir `pwd`:"
echo "------------------------"
ls | grep "\.pem"


