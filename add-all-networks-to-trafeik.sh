#!/bin/bash

TRAEFIK_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i traefik)

if [ -n "$TRAEFIK_CONTAINER" ]; then
  NETWORKS=$(docker network ls -f driver=bridge | awk '{print $2}' | tail -n +2 | tr "\n" " ")

  for i in $NETWORKS; do
      docker network connect "$i" "$TRAEFIK_CONTAINER"
  done
else
  echo "The traefik container could not be found. Is it running?"
fi
