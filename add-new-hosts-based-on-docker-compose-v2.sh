#!/bin/bash

DOCKER_COMPOSE=../docker-compose.yml

HOSTS_FILE=/etc/hosts

IP_FOR_NEW_DNS_RECORDS=127.0.0.1

URL_PARAMETER_NAME=PROJECT_BASE_URL

function add_hosts_from_a_docker_compose_file()
{
  DOCKER_COMPOSE=$1
  ACTION=$2
  
  if [ -s "$DOCKER_COMPOSE" ]; then
      ENV_FILE=$(dirname $DOCKER_COMPOSE)/.env
      
      grep -q "$URL_PARAMETER_NAME" $DOCKER_COMPOSE
      
      if [ ! -s "$ENV_FILE" -a "$?" -eq 0 ]; then
          echo "WARNING: file '$DOCKER_COMPOSE' was skipped because it does not have an .env file linked to it."
      else
          for i in $(cat $DOCKER_COMPOSE | grep Host | awk -F\` '{print $2}' | sed "s/\${${URL_PARAMETER_NAME}}/$(cat $ENV_FILE 2>/dev/null | grep "^${URL_PARAMETER_NAME}" | awk -F= '{print $2}')/")
          do
              grep -q "$i" $HOSTS_FILE 2>/dev/null

              if [ "$?" -eq 1 ]; then
                  if [ "$ACTION" == "update" ]; then
                      echo "Adding '$i' to '$HOSTS_FILE' ..."
                  
                      echo "$IP_FOR_NEW_DNS_RECORDS $i" | sudo tee -a $HOSTS_FILE &>/dev/null
                  else
                      if [ "$ACTION" == "list" ]; then
                          echo "Found host '$i' that needs to be updated in '$DOCKER_COMPOSE'."
                      fi
                  fi
              else
                  echo $i
              fi
          done
      fi
  else
      echo "ERROR! docker compose file could not be found as '$DOCKER_COMPOSE'."
      echo "Aborting ..."
  fi
}


if ! [ -s "$HOSTS_FILE" ]; then
    echo "ERROR! hosts file could not be found as '$HOSTS_FILE'."
    echo "Aborting ..."
    
    exit 1
fi


SCRIPT_LOC=$(dirname $(readlink -f "${BASH_SOURCE:-$0}"))

cd $SCRIPT_LOC


if [ "$1" == "update" ]; then
    add_hosts_from_a_docker_compose_file $DOCKER_COMPOSE "update"
else
    if [ "$1" == "list" ]; then
        add_hosts_from_a_docker_compose_file $DOCKER_COMPOSE "list"
    else
        if [ -d "$1" -a "$2" == "update" ]; then
            find $1 -type f -name $DOCKER_COMPOSE | while read line; do add_hosts_from_a_docker_compose_file $line "update"; done
        else
            if [ -d "$1" -a "$2" == "list" ]; then
                find $1 -type f -name $DOCKER_COMPOSE | while read line; do add_hosts_from_a_docker_compose_file $line "list"; done
            else
                echo "Wrong Usage!"
                echo "Usage:"
                echo "Option 1: $0 update - updates /etc/hosts file based on the '$DOCKER_COMPOSE' file present on script location."
                echo "Option 2: $0 list - lists hosts to be updated based on the '$DOCKER_COMPOSE' file present on script location."                
                echo "Option 3: $0 /path/to/dir update - scans the folder '/path/to/dir' recursively and updates /etc/hosts file based on each and every '$DOCKER_COMPOSE' files found."
                echo "Option 4: $0 /path/to/dir list - scans the folder '/path/to/dir' recursively and lists hosts that may be updated based on each and every '$DOCKER_COMPOSE' files found."
            fi
        fi
    fi
fi

