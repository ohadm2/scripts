#!/bin/bash

DOCKER_COMPOSE_FILESPEC=docker-compose.yml

DOCKER_COMPOSE_DEFAULT_NAME=docker-compose.yml

DOCKER_COMPOSE_BINARY_NAME=docker-compose


if ! [ -z "$1" ]; then
    if [ "$1" == "build" ]; then
        BUILD="--build"
    else
        if [ "$1" == "stop" ]; then
            STOP=yes
        else
            if [ -s "$1" ]; then
                DOCKER_COMPOSE_FILESPEC=$1
            fi
        fi
    fi
fi


SCRIPT_LOC=$(dirname $(readlink -f "${BASH_SOURCE:-$0}"))

cd $SCRIPT_LOC


if [ -s ./$DOCKER_COMPOSE_BINARY_NAME ]; then
   COMPOSE_STATUS=$(which $DOCKER_COMPOSE_BINARY_NAME)
   
   if [ -z "$COMPOSE_STATUS" ]; then
      sudo cp ./$DOCKER_COMPOSE_BINARY_NAME /usr/local/bin
   fi
fi

COMPOSE_STATUS=$(which $DOCKER_COMPOSE_BINARY_NAME)

if [ -z "$COMPOSE_STATUS" ]; then
  docker compose &>/dev/null  
  
  if [ "$?" -eq 0 ]; then
    DOCKER_COMPOSE_BINARY_NAME="docker compose"
  else
    echo "ERROR! Cannot find a valid docker compose binary."
    echo "Exiting ..."
  
    exit 2
  fi
fi


if ! [ -s "$DOCKER_COMPOSE_FILESPEC" ]; then 
    if [ -s ../"$DOCKER_COMPOSE_FILESPEC" ]; then
      DOCKER_COMPOSE_FILESPEC=../"$DOCKER_COMPOSE_FILESPEC"
    else
      echo "ERROR! Cannot find docker compose yml in '$DOCKER_COMPOSE_FILESPEC'. Please check the script and try again."
      echo "Aborting ..."
    
      exit 2
   fi
fi

if [ "$2" == "build" ]; then
    BUILD="--build"
fi

if [ "$STOP" == "yes" ]; then
    echo "Running '$DOCKER_COMPOSE_BINARY_NAME -f $DOCKER_COMPOSE_FILESPEC down' ..."
    $DOCKER_COMPOSE_BINARY_NAME -f $DOCKER_COMPOSE_FILESPEC down    
else
    echo "Adding the new env network to portainer ..."
    echo

    TRAEFIK_CONTAINER=$(sudo docker ps --format '{{.Names}}' | grep -i traefik)
    
    PROJECT_LOC=$(dirname $(readlink -f $DOCKER_COMPOSE_FILESPEC))
    
    if [ -s "$PROJECT_LOC/.env" ]; then
      . $PROJECT_LOC/.env
      
      if [ -z "$PROJECT_NAME" ]; then
        # if .env does not exist try to get the project name from docker-compose output
        PROJECT_NAME=$($DOCKER_COMPOSE_BINARY_NAME ls | grep $(basename $PROJECT_LOC) | awk '{print $1}')

        if [ -n "$PROJECT_NAME" ]; then
          NEW_ENV_NETWORK_NAME=${PROJECT_NAME}_default

          if [ -n "$TRAEFIK_CONTAINER" ]; then
            sudo docker network connect "$NEW_ENV_NETWORK_NAME" "$TRAEFIK_CONTAINER"
          fi
        fi
      else
        NEW_ENV_NETWORK_NAME=${PROJECT_NAME}_default

        if [ -n "$TRAEFIK_CONTAINER" ]; then
          sudo docker network connect "$NEW_ENV_NETWORK_NAME" "$TRAEFIK_CONTAINER"
        fi
      fi
    else
      PROJECT_NAME=$($DOCKER_COMPOSE_BINARY_NAME ls | grep $(basename $PROJECT_LOC) | awk '{print $1}')
    
      if [ -n "$PROJECT_NAME" ]; then
        NEW_ENV_NETWORK_NAME=${PROJECT_NAME}_default

        if [ -n "$NEW_ENV_NETWORK_NAME" -a -n "$TRAEFIK_CONTAINER" ]; then
          sudo docker network connect "$NEW_ENV_NETWORK_NAME" "$TRAEFIK_CONTAINER"
        fi
      fi
    fi

    echo "Running '$DOCKER_COMPOSE_BINARY_NAME -f $DOCKER_COMPOSE_FILESPEC up -d $BUILD' ..."
    $DOCKER_COMPOSE_BINARY_NAME -f $DOCKER_COMPOSE_FILESPEC up -d $BUILD
    
    if ! [ "$?" -eq 0 ]; then
      echo
      echo
      echo "ERROR! Something went wrong :("
      echo "Please check the error from docker compose."
      echo "Exting ..."
      
      exit 1
    fi
fi


sleep 3

echo
echo
echo "Showing env details:"
echo "---------------------"
echo

# assuming the latest running container has the relevant project name
#PROJECT_NAME=$(docker ps --format '{{.Names}}' | head -1 | rev | awk -F_ '{$1=""; print}' | rev | tr " " "_")

if [ -n "$PROJECT_NAME" ]; then

  echo "IP addresses:"
  echo "---------------------"
  echo

  for i in $($DOCKER_COMPOSE_BINARY_NAME ps | tail +2 | awk '{print $1}'); do echo $i; done | xargs -I {} bash -c "echo \"{} \" && docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' {}"

  echo
  echo
  echo "General info:"
  echo "---------------------"

  docker ps | grep $PROJECT_NAME

  echo
  echo "OS info:"
  echo "---------------------"

  for i in $($DOCKER_COMPOSE_BINARY_NAME ps | tail +2 | awk '{print $1}'); do echo $i; done | xargs -I {} bash -c "echo \"{}\": && docker exec \"{}\" grep \"ID.*\" /etc/os-release && echo -e \"\n\""

  echo
  echo

  echo "Exec cmds:"
  echo "----------------------------"


  for i in $($DOCKER_COMPOSE_BINARY_NAME ps | tail +2 | awk '{print $1}'); do echo $i; done | xargs -I {} bash -c "echo docker exec -it \"{}\" bash \(or ash\)"

  echo
  echo

  echo "Get logs:"
  echo "----------------------------"
  echo


  for i in $($DOCKER_COMPOSE_BINARY_NAME ps | tail +2 | awk '{print $1}'); do echo $i; done | xargs -I {} bash -c "echo docker logs \"{}\""

  echo
else
  echo "No extra info to show. Could not get the project name. Maybe you're missing some docker permissions?"
fi

# sudo killall -9 /usr/libexec/docker/cli-plugins/docker-compose


