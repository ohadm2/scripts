#!/bin/bash

if [ -s "$1" ]; then
  openssl x509 -inform der -in $1 -out certificate.pem
else
  echo "'$1' is not a valid file."
  echo "Usage: $0 <der-format-cert-file>"
fi
