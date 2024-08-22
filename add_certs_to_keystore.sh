#!/bin/bash

# Check if the input file was provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <input_file>"
    exit 1
fi

input_file=$1

# Define the Java keystore file and password
keystore_file="cacerts"
keystore_pass="changeit"  # Default password for Java keystore

# Create a temporary directory
temp_dir=$(mktemp -d)

# Loop through each line in the input file
while read -r line; do
    if [ -n "$line" ]; then
      cert_file=$(mktemp -p "$temp_dir" cert_XXXXXX.pem)
      echo "-----BEGIN CERTIFICATE-----" > "$cert_file"
      echo "$line" >> "$cert_file"
      echo "-----END CERTIFICATE-----" >> "$cert_file"

      # Add the certificate to the Java keystore
      keytool -import -trustcacerts -noprompt -alias "cert-$(basename $cert_file)" -file "$cert_file" -keystore "$keystore_file" -storepass "$keystore_pass"

      # Remove the temporary certificate file
      #rm "$cert_file"
    fi

done < "$input_file"

# Remove the temporary directory
#rm -rf "$temp_dir"

echo $temp_dir 
ls $temp_dir

echo "CA certificates added to Java keystore: $keystore_file"

