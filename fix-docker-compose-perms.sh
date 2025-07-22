#!/bin/bash

FILES_TO_CHECK="/home/$USERNAME/.docker/buildx/current /home/$USERNAME/.docker/buildx/activity/default"

if [ -n "$USERNAME" ]; then
  for FILE_TO_CHECK in $FILES_TO_CHECK
  do
    if [ -s "$FILE_TO_CHECK" ]; then
        if ! [ "$(stat -c '%U' "$FILE_TO_CHECK")" == "$USERNAME" ]; then
          echo "The file perms for $FILE_TO_CHECK need to be fixed."
          
          sudo chown $USERNAME:$USERNAME $FILE_TO_CHECK
          
          if [ "$?" -eq 0 ]; then
            echo "The file perms for $FILE_TO_CHECK Fixed."
          else
            echo "Unexpected error ($FILE_TO_CHECK)."
          fi
        else
          echo "No fix required for $FILE_TO_CHECK."
        fi
    else
      echo "No file to fix."
    fi
  done
else
    echo "Are you root? Run this script a s a normal user."
fi

