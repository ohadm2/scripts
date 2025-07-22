#!/bin/bash

ENV_FILESPEC=../.env

GITCONFIG_FILE_NAME=gitconfig

PHP_IMAGE_PROJECT_DIR_NAME=php.docker

SCRIPT_UPDATE_HOSTS_FILE=add-new-hosts-based-on-docker-compose-v2.sh
SCRIPT_CREATE_NEW_TERMINAL_PROFILE=dconf-add-profile-v2.sh
SCRIPT_CREATE_NEW_VSCODE_PROFILE=create-vscode-debugging-profile-v2.sh
SCRIPT_RUN_DOCKER_COMPOSE=start-or-stop-docker-env-v2.sh
SCRIPT_UPDATE_SETTINGS_PHP_FILE=update-settings-php-file.sh

DOCKER_USER_ID=1000
TIME_TO_WAIT_IN_SECONDS=20

EXPECTED_NUM_OF_ITEMS_IN_DIGITS=5

SCRIPT_LOC=$(dirname $(readlink -f "${BASH_SOURCE:-$0}"))

cd "$SCRIPT_LOC"

SITE_LOC=$(readlink -f $SCRIPT_LOC/../../)


# verify that we have a number of objects in the site location that match a drupal web site
CURRENT_NUM_OF_ITEMS=$(find $SITE_LOC -type f | grep -v "git" | wc -l)
CURRENT_NUM_OF_ITEMS_IN_DIGITS=$(printf $CURRENT_NUM_OF_ITEMS | wc -c)

if ! [ "$EXPECTED_NUM_OF_ITEMS_IN_DIGITS" == "$CURRENT_NUM_OF_ITEMS_IN_DIGITS" ]; then
  echo "ERROR! Looks like we don't have the full code here."
  echo "Please make sure that you are running the script from the correct location."
  echo "Aborting ..."
  exit 1
fi

# without .env file we won't get many mandatory parameters
if ! [ -s "$ENV_FILESPEC" ]; then
  echo "ERROR! Could not find the '.env' file in '$ENV_FILESPEC'."
  echo "Aborting ..."
  exit 2
fi

. $ENV_FILESPEC
# settings taken from .env: PROJECT_NAME, MYSQL_INIT_DB_HOST_FOLDER, MYSQL_DB_DATA_HOST_FOLDER, PROJECT_HOST_MOUNTS_LOCATION, DB_HOST, DB_PORT, DB_DRIVER, DB_NAME, DB_USER, PHP_XDEBUG_CLIENT_PORT, HOST_USER_NAME


# we must run this script using a valid username because we add user-level settings so i case we won't get the user from the env file we will try another way
if [ -n "$USERNAME" ]; then
  HOST_USER_NAME=$USERNAME
else
  echo "ERROR! Cannot detect current username. This script must be ran from a user environment (use -E if you are running this script via sudo)."
  echo "Aborting ..."

  exit 3
fi


NEW_PROFILE_VISIBLE_NAME="docker ${PROJECT_NAME}"
NEW_PROFILE_CUSTOM_CMD="docker exec -it ${PROJECT_NAME}_php bash"

BASIC_DB_FILE_NAME=basic-db-${PROJECT_NAME}.sql

echo "Hi."
echo
echo "This script will assist you with creating new settings for your new environment."
echo
echo "The following parts will be created automatically:"
echo
echo "1. Folders for the new environment."
echo "2. A basic DEFAULT settings.php file connected to the db."
echo "3. A basic DEFAULT DB without any data and a single user just to verify system integrity (you will be asked to provide a username and a password for it)."
echo "4. A terminal profile for getting into the container responsible of git operations."
echo "5. A vscode profile for debugging the site."
echo "6. Relevant new hosts will be added to /etc/hosts."
echo
echo
echo "The following parts will be created based on user's choice (only if needed):"
echo
echo "1. Git personal settings (name and email)."
echo "2. Mysql passwords (root and user)."
echo "3. Drupal site admin user and password."
echo
echo
echo "OK, here we go ..."
echo


# check system status (required for the next status checks)

PHP_CONTAINER_STATUS=$(docker images | grep "^${PROJECT_NAME}")

if [ -z "$PHP_CONTAINER_STATUS" ]; then
  # if there aren't images created from this project yet, we consider it a first run and force the whole script to run
  CANT_RUN_OTHER_CHECKS=yes
else
  PHP_CONTAINER_STATUS=$(docker ps | grep "${PROJECT_NAME}_php")

  if [ -z "$PHP_CONTAINER_STATUS" ]; then
    sudo -E bash ./$SCRIPT_RUN_DOCKER_COMPOSE build

    if [ "$?" -eq 0 ]; then
      echo "Waiting for the system to start ..."
      echo

      sleep $TIME_TO_WAIT_IN_SECONDS
    else
      CANT_RUN_OTHER_CHECKS=yes
    fi
  fi
fi

# check statuses of personal info existance

# gitconfig is not a docker inner check so we need to do it outside of docker related checks
if [ -s ~/.gitconfig ]; then
  #if [ -d "$SCRIPT_LOC"/"$PHP_IMAGE_PROJECT_DIR_NAME" ]; then
  #  if ! [ -s $SCRIPT_LOC/$PHP_IMAGE_PROJECT_DIR_NAME/gitconfig ]; then
  #    sudo cp -v ~/.gitconfig $SCRIPT_LOC/$PHP_IMAGE_PROJECT_DIR_NAME/gitconfig
  #  fi
  #fi
  
  NUM_OF_LINES=$(cat ~/.gitconfig | grep "name\|email" | wc -l)

  if [ "$NUM_OF_LINES" -eq 2 ]; then
    GIT_CONFIG_STATUS=exists
  else
    GIT_CONFIG_STATUS=''
  fi
fi  

if [ -z "$CANT_RUN_OTHER_CHECKS" ]; then
  #GIT_CONFIG_STATUS=$(docker exec ${PROJECT_NAME}_php bash -c "ls /home/\$PHP_FPM_USER/.gitconfig 2>/dev/null")
  MYSQL_PWDS_STATUS=$(ls ${SITE_LOC}/dockers/${PASSWORD_FILES_SRC_LOCATION}${USER_PASSWORD_FILE_NAME})
  DRUPAL_ADMIN_USER_STATUS=$(docker exec ${PROJECT_NAME}_php bash -c "if [ -n \"$(drush uinf 2 2>/dev/null)\" -o -n \"$(drush uinf --uid=1 2>/dev/null)\" ]; then echo exists; fi")

  # if a gitconfig exists locally copy it to the container
  #if [ -s ~/.gitconfig ]; then
  #  PHP_FPM_USER=$(docker exec ${PROJECT_NAME}_php bash -c "echo \$PHP_FPM_USER")

  #  if [ -n "$PHP_FPM_USER" ]; then
  #    docker cp ~/.gitconfig "${PROJECT_NAME}_php:/home/$PHP_FPM_USER/"
  #    docker exec ${PROJECT_NAME}_php bash -c "sudo chown \$PHP_FPM_USER /home/\$PHP_FPM_USER/.gitconfig"
  #  else
  #    echo "WARNING: Could not create gitconfig file for the user. Please create it manually."
  #    echo
  #  fi
  #fi
fi

# getting some info from the user that we can't get elsewhere

if [ -z "$GIT_CONFIG_STATUS" -o -z "$MYSQL_PWDS_STATUS" -o -z "$DRUPAL_ADMIN_USER_STATUS" ]; then
  echo
  echo  
  echo "Let's get the stuff I need from you :)"
  echo
  echo
fi

if [ -z "$GIT_CONFIG_STATUS" ]; then
  echo "Please supply git information (name and email):"
  echo

  read -p "Name: " name
  read -p "Email: " email

  if [ -z "$name" -o -z "$email" ]; then
    echo "ERROR! The process cannot continue until you fill in these details (git)."
    echo "Aborting ..."

    exit 4
  fi
else
  echo "INFO: Looks like you already have a gitconfig file. If you want to recreate it just rename or remove it and then re-run this script."
fi

if [ -z "$MYSQL_PWDS_STATUS" ]; then
  echo
  echo "Please supply mysql passwords (root and user):"
  echo

  read -p "Root Password: " root_pwd
  read -p "User Password: " user_pwd

  if [ -z "$root_pwd" -o -z "$user_pwd" ]; then
    echo "ERROR! The process cannot continue until you fill in these details (mysql)."
    echo "Aborting ..."

    exit 5
  fi

  echo "Creating secret files based on you given details ..."
  echo

  if [ -s "${SITE_LOC}/dockers/${PASSWORD_FILES_SRC_LOCATION}${ROOT_PASSWORD_FILE_NAME}" ]; then
    sudo rm -v ${SITE_LOC}/dockers/${PASSWORD_FILES_SRC_LOCATION}${ROOT_PASSWORD_FILE_NAME}
  fi

  if [ -s "${SITE_LOC}/dockers/${PASSWORD_FILES_SRC_LOCATION}${USER_PASSWORD_FILE_NAME}" ]; then
    sudo rm -v ${SITE_LOC}/dockers/${PASSWORD_FILES_SRC_LOCATION}${USER_PASSWORD_FILE_NAME}
  fi

  sudo mkdir -v -p ${SITE_LOC}/dockers/${PASSWORD_FILES_SRC_LOCATION}

  echo $root_pwd | sudo tee ${SITE_LOC}/dockers/${PASSWORD_FILES_SRC_LOCATION}${ROOT_PASSWORD_FILE_NAME}
  echo $user_pwd | sudo tee ${SITE_LOC}/dockers/${PASSWORD_FILES_SRC_LOCATION}${USER_PASSWORD_FILE_NAME}
  
  sudo chown -R $HOST_USER_NAME ${SITE_LOC}/dockers/${PASSWORD_FILES_SRC_LOCATION}
else
    echo "INFO: Looks like you already have mysql pwds file(s). If you want to recreate them just rename or remove them and then re-run this script."
fi

if [ -z "$DRUPAL_ADMIN_USER_STATUS" ]; then
  echo
  echo "Please supply root user details for drupal (uid=1) (username and password):"
  echo

  read -p "Username: " username
  read -p "Password: " password

  if [ -z "$username" -o -z "$password" ]; then
    echo "ERROR! The process cannot continue until you fill in these details (drupal)."
    echo "Aborting ..."

    exit 6
  fi
else
  echo "INFO: Looks like you already setup an admin user. Skipping ..."
fi


echo
echo "Updating site permissions ..."
echo

sudo chown -R $DOCKER_USER_ID:$DOCKER_USER_ID $SITE_LOC


echo "Creating folders (if needed ...)"
echo

if ! [ -d "$MYSQL_DB_DATA_HOST_FOLDER" ]; then
  sudo mkdir -v -p $MYSQL_DB_DATA_HOST_FOLDER
  
  if ! [ "$?" -eq 0 ]; then
    echo "ERROR! Could not create the folder '$MYSQL_DB_DATA_HOST_FOLDER'."
    echo "Aborting ..."
    
    exit 7
  fi
else
  echo "Looks like the folder '$MYSQL_DB_DATA_HOST_FOLDER' already exists. Nothing to do here."
  echo "Continuing ..."
  echo
fi

if ! [ -d "$MYSQL_INIT_DB_HOST_FOLDER" ]; then
  sudo mkdir -v -p $MYSQL_INIT_DB_HOST_FOLDER
  
  if ! [ "$?" -eq 0 ]; then
    echo "ERROR! Could not create the folder '$MYSQL_INIT_DB_HOST_FOLDER'."
    echo "Aborting ..."
    
    exit 8
  fi
else
  echo "Looks like the folder '$MYSQL_INIT_DB_HOST_FOLDER' already exists. Nothing to do here."
  echo "Continuing ..."
  echo
fi

if ! [ -s "$MYSQL_INIT_DB_HOST_FOLDER"/"$BASIC_DB_FILE_NAME" ]; then
  echo "Copying '$BASIC_DB_FILE_NAME' to '$MYSQL_INIT_DB_HOST_FOLDER' ..."
  echo

  sudo cp -v ../$BASIC_DB_FILE_NAME $MYSQL_INIT_DB_HOST_FOLDER
  sudo chmod -R a+rx $MYSQL_INIT_DB_HOST_FOLDER
fi

echo "Creating an empty bash history file ..."
echo

if ! [ -e "${PROJECT_HOST_MOUNTS_LOCATION}/docker_bash_history_${PROJECT_NAME}" ]; then
  sudo touch ${PROJECT_HOST_MOUNTS_LOCATION}/docker_bash_history_${PROJECT_NAME}
  sudo chmod a+rw ${PROJECT_HOST_MOUNTS_LOCATION}/docker_bash_history_${PROJECT_NAME}
fi

echo "Creating settings.php file ..."
echo

if [ ! -s "${SITE_LOC}/sites/default/settings.php" -a -s "${SITE_LOC}/sites/default/default.settings.php" ]; then
  SETTINGS_DATA="host:${DB_HOST},port:${DB_PORT},driver:${DB_DRIVER},database:${DB_NAME},username:${DB_USER},password:$(cat ${SITE_LOC}/dockers/${PASSWORD_FILES_SRC_LOCATION}${USER_PASSWORD_FILE_NAME})"

  bash ./$SCRIPT_UPDATE_SETTINGS_PHP_FILE "${SITE_LOC}/sites/default/default.settings.php" "${SETTINGS_DATA}" "${SITE_LOC}"

  #echo "bash ./$SCRIPT_UPDATE_SETTINGS_PHP_FILE \"${SITE_LOC}/sites/default/default.settings.php\" \"${SETTINGS_DATA}\" \"${SITE_LOC}\""
else
  echo "WARNING: The file '$SITE_LOC/sites/default/settings.php' already exists and will NOT be overwritten."
  echo
fi


echo "Updating hosts file with new env hosts ..."
echo

sudo bash ./$SCRIPT_UPDATE_HOSTS_FILE update


if [ -n "$HOST_USER_NAME" ]; then
  echo
  echo "UI terminal profile: Trying to create a new terminal profile for the env ..."
  echo
      
  bash ./$SCRIPT_CREATE_NEW_TERMINAL_PROFILE "$HOST_USER_NAME" "$NEW_PROFILE_VISIBLE_NAME" "$NEW_PROFILE_CUSTOM_CMD"

  if ! [ "$?" -eq 0 ]; then
    echo "INFO: Failed to create a new UI terminal profile for user '$HOST_USER_NAME'."
    echo "Try to fix manually."
    echo
  fi

  echo
  echo "Vscode profile: Trying to add an Xdebug profile to vscode ..."
  echo

  bash ./$SCRIPT_CREATE_NEW_VSCODE_PROFILE "$HOST_USER_NAME" "$SITE_LOC" "$PROJECT_NAME" "$PHP_XDEBUG_CLIENT_PORT"


  # run docker-compose
  echo
  echo "Running docker-compose ..."
  echo

  sudo -E bash ./$SCRIPT_RUN_DOCKER_COMPOSE start

  echo "Waiting for the system to start ..."
  echo

  sleep $TIME_TO_WAIT_IN_SECONDS

  if [ "$?" -eq 0 ]; then
    echo "Adding the new env network to portainer ..."
    echo

    TRAEFIK_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i traefik)
    NEW_ENV_NETWORK_NAME=${PROJECT_NAME}_default

    docker network connect "$NEW_ENV_NETWORK_NAME" "$TRAEFIK_CONTAINER"

    if [ -z "$DRUPAL_ADMIN_USER_STATUS" ]; then
      echo
      echo "Updating the drupal root user using your given details ..."
      echo

      docker exec ${PROJECT_NAME}_php drush status | grep -q "Connected"

      if [ "$?" -eq 0 ]; then
        docker exec ${PROJECT_NAME}_php bash -c "drush user-create ${username} --mail=\"no_one@dot.local\" --password=\"${password}\"; drush user-add-role \"administrator\" ${username}"

        if ! [ "$?" -eq 0 ]; then
          echo
          echo "WARNING: Could not create the user. Please create it manually."
          echo
        fi
      else
        echo
        echo "WARNING: Could not detect a valid connection to the DB. Please create the user manually."
        echo
      fi
    fi

    if [ -z "$GIT_CONFIG_STATUS" ]; then
      echo "Creating or updating a '~/.gitconfig' file based on you given details ..."
      echo

      if [ -s ~/.gitconfig ]; then
        #mv -v ~/.gitconfig ~/gitconfig.bak.$(date "+%s")
        NUM_OF_LINES=$(cat ~/.gitconfig | grep "name\|email" | wc -l)

        if ! [ "$NUM_OF_LINES" -eq 2 ]; then
          grep -q "\[user\]" ~/.gitconfig
          
          if [ "$?" -eq 0 ]; then
            sed -i '/\[user\]/a \\temail\ =\ '${email} ~/.gitconfig
            sed -i '/\[user\]/a \\tname\ =\ '${name} ~/.gitconfig
          else
            echo -e "[user]\nname = ${name}\nemail = ${email}\n" >> ~/.gitconfig
          fi
        fi
      else
        echo -e "[user]\nname = ${name}\nemail = ${email}\n" > ~/.gitconfig
      fi
    fi
    
    #if [ -s ~/.gitconfig ]; then
      #PHP_FPM_USER=$(docker exec ${PROJECT_NAME}_php bash -c "echo \$PHP_FPM_USER")
      
    #  if [ -n "$PHP_FPM_USER" ]; then
    #    docker cp ~/.gitconfig "${PROJECT_NAME}_php:/home/$PHP_FPM_USER/"
    #    docker exec ${PROJECT_NAME}_php bash -c "sudo chown \$PHP_FPM_USER /home/\$PHP_FPM_USER/.gitconfig"
    #  else
    #    echo "WARNING: Could not create gitconfig file for the user. Please create it manually."
    #    echo
    #  fi
    #fi
  fi
fi


echo
echo
echo "Checks:"
echo "========"
echo

git config -l

echo

docker exec ${PROJECT_NAME}_php drush status

echo


if [ -s "${SITE_LOC}/core" ]; then
  DRUPAL_UID='--uid=1'
else
  DRUPAL_UID='2'
fi

docker exec ${PROJECT_NAME}_php drush uinf $DRUPAL_UID








