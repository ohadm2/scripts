#!/bin/bash

# Version 2.31

DOCKER_COMPOSE_FILESPEC=docker-compose.yml

DOCKER_COMPOSE_DEFAULT_NAME=docker-compose.yml

DOCKER_COMPOSE_BINARY_NAME=docker-compose

SCRIPT_GET_ENV_URLS=add-new-hosts-based-on-docker-compose-v2.01.sh

DRUPAL_7_MYSQL_CONTAINER_NAME=d7_mysql


if ! [ -z "$1" ]; then
    if [ "$1" == "build" ]; then
        BUILD="--build"
    else
        if [ "$1" == "stop" ]; then
            STOP=yes
        else
          if [ "$1" == "status" ]; then
              STATUS=yes
          else
            if [ "$1" == "reset" ]; then
              RESET=yes
            else
              if [ "$1" == "help" ]; then
                HELP=yes
              else
                if [ -s "$1" ]; then
                    DOCKER_COMPOSE_FILESPEC=$1
                fi
              fi
            fi
          fi
        fi
    fi
fi


SCRIPT_LOC=$(dirname $(readlink -f "${BASH_SOURCE:-$0}"))

cd "$SCRIPT_LOC"


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


if [ "$HELP" == "yes" ]; then
  echo "Options:"
  echo
  echo "Actions (on default yml):"
  echo
  echo "$0 start - start this docker compose environment"
  echo "$0 build - build and start this docker compose environment"  
  echo "$0 stop - stop this docker compose environment"
  echo "$0 status - get status of ALL docker compose environments"
  echo "$0 reset - stop ALL docker compose environments"
  echo "$0 help - get this help"
  echo
  echo "Non-default yml usage:"
  echo "$0 <compose-yml> <action> - run an option on a custom yml file"
  
  exit 0
fi


if [ "$RESET" == "yes" ]; then
  $DOCKER_COMPOSE_BINARY_NAME ls | grep "running" | awk '{print $3}' | xargs -I {} $DOCKER_COMPOSE_BINARY_NAME -f {} stop
  
  docker ps -a | tail +2 | awk '{print $1}' | xargs -I {} docker rm -f {}
  
  exit 0
fi

if [ "$STATUS" == "yes" ]; then
  echo "Current env ps status: (empty list means 'system is down')"
  echo
  
  $DOCKER_COMPOSE_BINARY_NAME -f $DOCKER_COMPOSE_FILESPEC ps
  
  echo
  echo "All compose based systems: (empty list means 'there are no other systems currently running')"
  echo
  
  $DOCKER_COMPOSE_BINARY_NAME -f $DOCKER_COMPOSE_FILESPEC ls
  
  echo
  echo "TIP: run '$0 reset' to stop other systems before starting another if name conflicts may occur."
  exit 0
fi

if [ "$2" == "build" ]; then
    BUILD="--build"
fi

if [ "$STOP" == "yes" ]; then
    echo "Running '$DOCKER_COMPOSE_BINARY_NAME -f $DOCKER_COMPOSE_FILESPEC down' ..."
    $DOCKER_COMPOSE_BINARY_NAME -f $DOCKER_COMPOSE_FILESPEC down
else
    echo "Running '$DOCKER_COMPOSE_BINARY_NAME -f $DOCKER_COMPOSE_FILESPEC up -d $BUILD' ..."
    $DOCKER_COMPOSE_BINARY_NAME -f $DOCKER_COMPOSE_FILESPEC up -d $BUILD
    
    if ! [ "$?" -eq 0 ]; then
      echo
      echo
      echo "ERROR! Something went wrong :("
      echo "Please check the error from docker compose."
      echo "Exiting ..."
      
      exit 1
    fi
    
    echo
    echo "Adding the new env network to traefik ..."
    echo

    TRAEFIK_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i traefik)
    
    PROJECT_LOC=$(dirname $(readlink -f $DOCKER_COMPOSE_FILESPEC))
    
    if [ -s "$PROJECT_LOC/.env" ]; then
      . $PROJECT_LOC/.env
      
      if [ -z "$PROJECT_NAME" ]; then
        # if .env does not exist try to get the project name from docker-compose output
        PROJECT_NAME=$($DOCKER_COMPOSE_BINARY_NAME ls | grep $(basename $PROJECT_LOC) | awk '{print $1}')

        if [ -n "$PROJECT_NAME" ]; then
          NEW_ENV_NETWORK_NAME=${PROJECT_NAME}_default

          if [ -n "$TRAEFIK_CONTAINER" ]; then
            docker network connect "$NEW_ENV_NETWORK_NAME" "$TRAEFIK_CONTAINER"
          fi
          
          if [[ "$PROJECT_NAME" == *"d10"* || "$PROJECT_NAME" == *"d9"* || "$PROJECT_NAME" == *"d7"* ]]; then
            echo
            echo "Connecting $PROJECT_NAME to d7 for the migrate feature..."
            echo
            
            DRUPAL_7_NETWORK_NAME=$(docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' $DRUPAL_7_MYSQL_CONTAINER_NAME)
            
            if [ -n "$DRUPAL_7_NETWORK_NAME" ]; then
              docker network connect $DRUPAL_7_NETWORK_NAME "$PROJECT_NAME"_php
            fi
          fi
        fi
      else
        NEW_ENV_NETWORK_NAME=${PROJECT_NAME}_default

        if [ -n "$TRAEFIK_CONTAINER" ]; then
          docker network connect "$NEW_ENV_NETWORK_NAME" "$TRAEFIK_CONTAINER"
        fi
        
        if [[ "$PROJECT_NAME" == *"d10"* || "$PROJECT_NAME" == *"d9"* || "$PROJECT_NAME" == *"d7"* ]]; then
          echo
          echo "Connecting $PROJECT_NAME to d7 for the migrate feature..."
          echo
          
          DRUPAL_7_NETWORK_NAME=$(docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' $DRUPAL_7_MYSQL_CONTAINER_NAME)
          
          if [ -n "$DRUPAL_7_NETWORK_NAME" ]; then
            docker network connect $DRUPAL_7_NETWORK_NAME "$PROJECT_NAME"_php
          fi
        fi  
      fi
    else
      PROJECT_NAME=$($DOCKER_COMPOSE_BINARY_NAME ls | grep $(basename $PROJECT_LOC) | awk '{print $1}')
    
      if [ -n "$PROJECT_NAME" ]; then
        NEW_ENV_NETWORK_NAME=${PROJECT_NAME}_default

        if [ -n "$NEW_ENV_NETWORK_NAME" -a -n "$TRAEFIK_CONTAINER" ]; then
          docker network connect "$NEW_ENV_NETWORK_NAME" "$TRAEFIK_CONTAINER"
        fi
        
        if [[ "$PROJECT_NAME" == *"d10"* || "$PROJECT_NAME" == *"d9"* || "$PROJECT_NAME" == *"d7"* ]]; then
          echo
          echo "Connecting $PROJECT_NAME to d7 for the migrate feature..."
          echo
          
          DRUPAL_7_NETWORK_NAME=$(docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' $DRUPAL_7_MYSQL_CONTAINER_NAME)
          
          if [ -n "$DRUPAL_7_NETWORK_NAME" ]; then
            docker network connect $DRUPAL_7_NETWORK_NAME "$PROJECT_NAME"_php
          fi        
        fi
      fi
    fi
fi


sleep 3

echo
echo
echo "Showing env details:"
echo "--------------------------------"
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
  echo

  echo "Sites and states:"
  echo "----------------------------"
  echo
  
  # Print table header
  printf "%-40s|%-10s\n" "Site" "Status"
  printf "%-40s|%-10s\n" "----------------------------------------" "-------------------"
  
  for i in $(./$SCRIPT_GET_ENV_URLS list 2>/dev/null)
  do
       if [ -n "$i" ]; then
         site="http://$i"
         
         status=$(curl --max-time 3 -I "$site" 2>/dev/null | head -1)
         
         if [ -z "$status" ]; then
           curl --max-time 3 -I "$site" &>/dev/null
           
           if [ "$?" -eq 6 ]; then
             status="Could not resolve host"
           fi  
         fi
         
         printf "%-40s|%-10s\n" "$site" "$status"
       fi
  done
  
  echo
  
else
  echo "No extra info to show. Could not get the project name. Maybe you're missing some docker permissions?"
fi

# sudo killall -9 /usr/libexec/docker/cli-plugins/docker-compose


