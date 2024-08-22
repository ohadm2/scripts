#!/bin/bash

USER_TO_INSTALL_FOR=auser

# Set the custom command, use-custom-cmd, and visible name
NEW_PROFILE_VISIBLE_NAME="docker d9 test"
custom_cmd="docker exec -it d9_test_php bash"
use_custom_cmd="true"

if ! [ -z "$1" ]; then
    if [ -z "$2" ]; then
        echo "Wrong usage!"
        echo "Usage: $0 <user_to_install_for> <profile-visible-name> <custom_cmd>"
        echo "All 3 params are mandatory!"
        echo "You must use quotes for every param that has a value of more than one word."
        echo "E.g: $0 devuser 'my new profile' 'docker exec -it d9_test_php bash'"
        
        exit 1
    else
        USER_TO_INSTALL_FOR=$1
    fi
fi

if ! [ -z "$2" ]; then
    NEW_PROFILE_VISIBLE_NAME=$2
fi

if ! [ -z "$3" ]; then
    custom_cmd=$3
fi

CURRENT_PROFILES_NAMES_LIST=$(gsettings get org.gnome.Terminal.ProfilesList list | tr -d "[" | tr -d "]" | tr -d "'" | tr -d "," | tr -d "\n" | xargs -d ' ' -I {} gsettings get org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:{}/ visible-name | tr "\n" " ")

#echo $CURRENT_PROFILES_NAMES_LIST | grep -q "^$NEW_PROFILE_VISIBLE_NAME$" 2>/dev/null

#echo "$CURRENT_PROFILES_NAMES_LIST | grep -q $NEW_PROFILE_VISIBLE_NAME"

IFS="'" read -r -a PROFILES_NAMES_ARRAY <<< "$CURRENT_PROFILES_NAMES_LIST"

# Loop through the array
for name in "${PROFILES_NAMES_ARRAY[@]}"; do
  if [[ "$name" == "$NEW_PROFILE_VISIBLE_NAME" ]]; then
    echo "INFO: The profile '$NEW_PROFILE_VISIBLE_NAME' already exists. Nothing to do ..."
    echo "Aborting ..."
    
    exit 0
  fi
done

echo "Creating a new terminal profile ..."

echo
echo "DEBUG: Input data: \$1 = \"$1\", \$2 = \"$2\", \$3 = \"$3\""

echo
echo "Creating a new UUID and basic structure ..."

profile_id=$(uuidgen)

echo
echo "DEBUG: profile_id = $profile_id"


dconf write "/org/gnome/terminal/legacy/profiles:/:$profile_id/visible-name" "'$NEW_PROFILE_VISIBLE_NAME'"

if ! [ "$?" -eq 0 ]; then
    echo "ERROR! Unexpected error occured (line 61)."
    echo "Aborting ..."
        
    exit 2
fi

dconf write "/org/gnome/terminal/legacy/profiles:/:$profile_id/custom-command" "'$custom_cmd'"

if ! [ "$?" -eq 0 ]; then
    echo "ERROR! Unexpected error occured (line 70)."
    echo "Aborting ..."
        
    exit 3
fi

dconf write "/org/gnome/terminal/legacy/profiles:/:$profile_id/use-custom-command" "$use_custom_cmd"

if ! [ "$?" -eq 0 ]; then
    echo "ERROR! Unexpected error occured (line 79)."
    echo "Aborting ..."
        
    exit 4
fi

echo
echo "DEBUG: data created inside the new profile (id: $profile_id): "

echo "visible-name: $(gsettings get org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$profile_id/ visible-name)"
echo "custom-command: $(gsettings get org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$profile_id/ custom-command)"
echo "use-custom-command: $(gsettings get org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$profile_id/ use-custom-command)"


echo
echo "Adding the new UUID to the 'list' array ..."

gsettings set org.gnome.Terminal.ProfilesList list "[$(gsettings get org.gnome.Terminal.ProfilesList list | tr -d '[' | tr -d ']'), '$profile_id']"

if ! [ "$?" -eq 0 ]; then
    echo "ERROR! Unexpected error occured (line 99)."
fi

echo "Done! You should see and use the new profile via the UI using the down arrow icon."

exit 0

# remove stuff:
# dconf reset -f /org/gnome/terminal/legacy/profiles:/:b5c2799c-15b6-4aed-afa9-d7726151f199/

# list
# dconf list /org/gnome/terminal/legacy/profiles:/
# dconf read /org/gnome/terminal/legacy/profiles:/list
# gsettings get org.gnome.Terminal.ProfilesList list


# gsettings get org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$profile_id/ visible-name

# gsettings set org.gnome.Terminal.ProfilesList list "[$(gsettings get org.gnome.Terminal.ProfilesList list | tr -d \"[\" | tr -d \"]\"), '95944aa8-78d2-4f5f-94cf-0afdf36624fd']"

# gsettings get org.gnome.Terminal.ProfilesList list | tr -d "[" | tr -d "]" | tr -d "'" | tr -d "," | tr -d "\n" | xargs -d ' ' -I {} gsettings get org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:{}/ visible-name



