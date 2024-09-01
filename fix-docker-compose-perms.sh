#!/bin/bash

FILE_TO_CHECK="/home/$USERNAME/.docker/buildx/current"

if [ -s "$FILE_TO_CHECK" ]; then
  if [ -n "$USERNAME" ]; then
    if ! [ "$(stat -c '%U' "$FILE_TO_CHECK")" == "$USERNAME" ]; then
      echo "The file perms for $FILE_TO_CHECK need to be fixed."
      
      sudo chown $USERNAME:$USERNAME $FILE_TO_CHECK
      
      if [ "$?" -eq 0 ]; then
        echo "Fixed."
      else
        echo "Unexpected error."
      fi
    else
      echo "No fix required."
    fi
  else
    echo "Are you root?"
  fi
else
  echo "No file to fix."
fi  

