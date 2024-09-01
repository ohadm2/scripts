#!/bin/bash

# Check if a directory was provided
if [ -z "$1" ]; then
  echo "Usage: $0 <directory>"
  exit 1
fi

# Function to extract ports from a docker-compose file
extract_ports() {
  declare -A unique_ports
  local file="$1"

  g_ports=$(grep -Eo "[^a-zA-Z'.][0-9]+:" "$file" | grep -Eo "[0-9]+" | tr '\n' ' ')
  t_ports=$(grep -Eo 'traefik\.http\.services\.[^.]+\.loadbalancer\.server\.port=[0-9]+' "$file" | grep -Eo "[0-9]+$" | tr '\n' ' ')
  p_ports=$(grep "PORTAINER_PORT=" "$file" | grep -Eo "[0-9]+$" | tr '\n' ' ')
  
  ports=$(echo "$g_ports $t_ports $p_ports")
  
  #echo $ports
  
  # Loop through the ports and add to the associative array
  for port in $ports; do
    unique_ports["$port"]=1
  done
  
  echo ${!unique_ports[@]} | tr ' ' '\n' | sort -n | tr '\n' ' '
}


echo "From files:"
echo "===================="
echo

# Scan the specified directory for docker-compose.yml files
find "$1" -type f \( -name "docker-compose*.yml" -o -name ".env" \) | while read -r compose_file; do
  echo "File $compose_file:"
  
  extract_ports "$compose_file"
  
  echo "${current_ports[@]}"
  
  echo
done


echo "From Containers:"
echo "===================="
echo

docker ps --format "Container {{.Names}}:\n {{.Ports}}" | sed 's#^\s*[0-9]*/tcp.*##g' | sed 's#\s*^[0-9]*/udp.*##g' | sed 's#\(0.0.0.0:[0-9]*\)->.*#\1#g'
