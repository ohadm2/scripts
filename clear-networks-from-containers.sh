#!/bin/bash

# Check if a partial network name is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <partial_network_name>"
    exit 1
fi

PARTIAL_NAME=$1

# Get the list of networks that match the partial name
NETWORKS=$(docker network ls --filter "name=$PARTIAL_NAME" --format "{{.Name}}")

# Loop through each network and detach connected containers
for NETWORK in $NETWORKS; do
    echo "Processing network: $NETWORK"

    # Get the list of containers connected to the network
    CONTAINERS=$(docker network inspect "$NETWORK" -f '{{range .Containers}}{{.Name}} {{end}}')

    # Loop through each container and disconnect it from the network
    for CONTAINER in $CONTAINERS; do
        echo "Detaching container: $CONTAINER from network: $NETWORK"
        docker network disconnect "$NETWORK" "$CONTAINER"
    done
done

echo "Completed detaching containers from networks matching: $PARTIAL_NAME"

