#!/bin/bash

if [ -s "$1" ]; then
  openssl x509 -inform der -in $1 -out $1.pem
else
  echo "'$1' is not a valid file."
fi
