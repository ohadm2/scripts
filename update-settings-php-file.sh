#!/bin/bash

# params:
# $1 = basic template file (from-another-site, from-script-dir)
# $2 = data to update (format: key1:value1,key2:value2 ...)
# $3 = destenation folder
# $4 = drupal version (not always mandatory)


# local basic template file name structure: <drupal-version>-settings-template.php e.g.: 7-settings-template.php


if [ "$1" == "" -o "$2" == "" -o "$3" == "" ]; then
  echo "ERROR! Wrong Usage!"
  echo "Usage: $0 <basic-template-file> <data-to-update> <destenation-folder> [drupal-version]"
  echo "basic-template-file: 1) a path to a file to use as a template, 2) 'script' or 'local' for using a local template"
  echo "data-to-update: the data to update (format: key1:value1,key2:value2 ...)"
  echo "destenation-folder: where to put the settings.php file"
  echo "drupal-version: '7', '9' '10' etc. Mandatory only when using local template as basic template"
fi


if [ -s "$1" ]; then
  BASIC_TEMPLATE_FILE=$1
else
  if [ -s "$4-settings-template.php" ]; then
    BASIC_TEMPLATE_FILE=$4-settings-template.php
  else
    echo "ERROR! Could not find a valid file under '$4-settings-template.php'. Please verify input and try again..."
    echo "Aborting ..."
    
    exit 1
  fi
fi  
  
if [ -d "$3" ]; then
  if [ -d "$3/sites/default" ]; then
    if ! [ -s "$3/sites/default/settings.php" ]; then
      cp -v $BASIC_TEMPLATE_FILE $3/sites/default/settings.php
      
      FILE_TO_WORK_ON=$3/sites/default/settings.php
      
      #if [ -s "$3/sites/default/default.settings.php" ]; then
      #  mv -v $3/sites/default/default.settings.php $3/sites/default/default.settings.php.dis
      #fi
    else
        echo "ERROR! The file '$3/sites/default/settings.php' already exists! Will NOT overwrite."
        echo "Aborting ..."
    
        exit 2
    fi
  else
    if ! [ -s "$3/settings.php" ]; then
      cp -v $BASIC_TEMPLATE_FILE $3/settings.php
      
      FILE_TO_WORK_ON=$3/settings.php
      
      #if [ -s "$3/default.settings.php" ]; then
      #  mv -v $3/default.settings.php $3/default.settings.php.dis
      #fi
    else
        echo "ERROR! The file '$3/sites/default/settings.php' already exists! Will NOT overwrite."
        echo "Aborting ..."
    
        exit 3    
    fi    
  fi
else
  echo "ERROR! Could not find a valid folder under '$3'. Please verify input and try again..."
  echo "Aborting ..."
  
  exit 3
fi


DB_CONNECTION_SEGMENT="\$databases['default']['default'] = array (
  'database' => '',
  'username' => '',
  'password' => '',
  'host' => '',
  'port' => '',
  'driver' => 'mysql',
  'namespace' => 'Drupal\\\\Core\\\\Database\\\\Driver\\\\mysql',
  'prefix' => '',
);"

CONFIG_SYNC_DIRECTORY_SETTINGS="\$settings['config_sync_directory'] = DRUPAL_ROOT . '/sites/default/config/sync';"

FILE_PRIVATE_PATH_SETTINGS="\$settings['file_private_path'] = 'sites/default/files/private';"

HASH_SALT_SETTINGS="\$settings['hash_salt'] = 'wuPJDyosbxTuq1zehYwRrnlZ6MOboXVu1490elFf5X0=';"


function updateASettingsFileUsingSed() {
  local -n pairs_arr=$1

  # Loop over each key-value pair
  for pair in "${pairs_arr[@]}"; do
      # Split the pair into key and value
      IFS=':' read -r key value <<< "$pair"
      #echo "Key: $key, Value: $value"
      
      sed -i "/^\s*#\|^\s*\\*\|^\s*\\/\\//! s/\(\s*'${key}'\ =>\ '\).*'/\1${value}'/" $FILE_TO_WORK_ON

      #echo "sed -i \"/^\s*#\|^\s*\\*\|^\s*\\/\\//! s/\(\s*'${key}'\ =>\ '\).*'/\1${value}'/\" $FILE_TO_WORK_ON"
  done
}



DATA_TO_UPDATE=$2

IFS_BKUP=$IFS

# Split the dictionary string into an array of key-value pairs
IFS=',' read -ra pairs <<< "$DATA_TO_UPDATE"

updateASettingsFileUsingSed pairs

BASIC_TEMPLATE_FILE_SIZE=$(stat -c%s $BASIC_TEMPLATE_FILE)
FILE_TO_WORK_ON_SIZE=$(stat -c%s $FILE_TO_WORK_ON)

# no change to file - means that the db section is remarked
if [ "$BASIC_TEMPLATE_FILE_SIZE" -eq "$FILE_TO_WORK_ON_SIZE" ]; then
  # if the db section was remarked we need to add a new one on our own and re-run the update function

  echo "$DB_CONNECTION_SEGMENT" >> $FILE_TO_WORK_ON

  updateASettingsFileUsingSed pairs

  echo "$CONFIG_SYNC_DIRECTORY_SETTINGS" >> $FILE_TO_WORK_ON
  echo "$FILE_PRIVATE_PATH_SETTINGS" >> $FILE_TO_WORK_ON
  echo "$HASH_SALT_SETTINGS" >> $FILE_TO_WORK_ON
fi


IFS=$IFS_BKUP








