#!/bin/bash

# start-saml-idp.sh

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

cd "$DIR"

if [[ ! -f idp-public-cert.pem ]]; then
  echo "Generating new SAML Certificates"
  openssl req \
    -x509 \
    -newkey rsa:1024 \
    -days 3650 \
    -nodes \
    -subj '/CN=localhost' \
    -keyout "idp-private-key.pem" \
    -out "idp-public-cert.pem"
fi

echo "Downloading and starting SAML-IdP"
export NPM_CONFIG_REGISTRY=https://registry.npmjs.org
exec npx saml-idp --acsUrl "http://localhost:7007/api/auth/saml/handler/frame" --audience "http://localhost:7007/api/auth/saml/metadata" --host 0.0.0.0 --port 7001

# http://172.22.0.1:7001/saml/sso


