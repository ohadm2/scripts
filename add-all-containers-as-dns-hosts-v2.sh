#!/bin/bash

# Script to add all running Docker containers to /etc/hosts

# Check if script is run as root (needed to modify /etc/hosts)
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root to modify /etc/hosts"
    echo "Try: sudo $0"
    exit 1
fi

# Docker hosts marker for easy identification
DOCKER_START_MARKER="# BEGIN DOCKER CONTAINER HOSTS"
DOCKER_END_MARKER="# END DOCKER CONTAINER HOSTS"

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker is not running or not accessible"
    exit 1
fi

# Create a temporary file for the new hosts entries
temp_file=$(mktemp)
echo "$DOCKER_START_MARKER" >> "$temp_file"
echo "# Generated on $(date)" >> "$temp_file"

echo "Scanning for all running Docker containers..."

# Track statistics
total_containers=0
updated_entries=0
preserved_entries=0
new_entries=0

# Create a temporary file for entries we want to preserve
hosts_to_preserve=$(mktemp)
# Copy the current hosts file without the Docker section
sed "/$DOCKER_START_MARKER/,/$DOCKER_END_MARKER/d" /etc/hosts > "$hosts_to_preserve"

# Get all running container IDs
mapfile -t container_ids < <(docker ps -q)
total_containers=${#container_ids[@]}

echo "Found $total_containers running containers"

for container_id in "${container_ids[@]}"; do
    # Get container name (removing the leading slash)
    container_name=$(docker inspect --format '{{.Name}}' "$container_id" | sed 's/^\///')
    
    # Get IP address - using a more compatible approach
    # First try the default bridge network
    ip=$(docker inspect --format '{{.NetworkSettings.IPAddress}}' "$container_id")
    
    # If empty, try networks
    if [ -z "$ip" ] || [ "$ip" = "<no value>" ]; then
        # Get all network data as JSON and extract first non-empty IP
        networks_json=$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$container_id")
        ip=$(echo "$networks_json" | grep -o '"IPAddress":"[0-9\.]*"' | head -1 | cut -d'"' -f4)
    fi
    
    # Skip if still no IP found
    if [ -z "$ip" ] || [ "$ip" = "<no value>" ]; then
        echo "Warning: No IP found for $container_name ($container_id) - skipping"
        continue
    fi
    
    # Check if entry already exists with CORRECT IP in hosts file (outside our markers)
    if grep -q "^$ip $container_name.docker $container_name$" "$hosts_to_preserve"; then
        echo "Entry for $container_name ($ip) already exists with correct IP - preserving"
        preserved_entries=$((preserved_entries + 1))
        # Remove this entry from hosts_to_preserve so we don't have duplication
        sed -i "/^$ip $container_name.docker $container_name$/d" "$hosts_to_preserve"
        continue
    fi
    
    # Check if container name exists but with DIFFERENT IP
    existing_entry=$(grep -E "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ $container_name.docker $container_name$" "$hosts_to_preserve")
    if [ -n "$existing_entry" ]; then
        old_ip=$(echo "$existing_entry" | awk '{print $1}')
        echo "Updating $container_name: IP changed from $old_ip to $ip"
        updated_entries=$((updated_entries + 1))
        # Remove the old entry with incorrect IP
        sed -i "/ $container_name.docker $container_name$/d" "$hosts_to_preserve"
    else
        echo "Adding new container $container_name with IP $ip"
        new_entries=$((new_entries + 1))
    fi
    
    # Add entry to temp file
    echo "$ip $container_name.docker $container_name" >> "$temp_file"
done

echo "$DOCKER_END_MARKER" >> "$temp_file"

# Handle output based on what was found
if [ "$new_entries" -eq 0 ] && [ "$updated_entries" -eq 0 ]; then
    echo "No new or updated container entries to add"
    if [ "$preserved_entries" -gt 0 ]; then
        echo "$preserved_entries container entries already exist with correct IP"
    fi
    rm "$temp_file" "$hosts_to_preserve"
    exit 0
fi

# Create the new hosts file by combining preserved entries with our Docker section
cat "$hosts_to_preserve" > /etc/hosts.new
cat "$temp_file" >> /etc/hosts.new
mv /etc/hosts.new /etc/hosts

# Clean up
rm "$temp_file" "$hosts_to_preserve"

echo "Done!"
echo "- $new_entries new container entries added"
echo "- $updated_entries container entries updated with new IPs"
echo "- $preserved_entries container entries preserved (already correct)"

