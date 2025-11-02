#!/bin/bash

NAUTILUS_SCRIPTS_LOCATION=/home/$USERNAME/.local/share/nautilus/scripts

TEMPLATE_FILES_LOCATION=/home/$USERNAME/Templates

GNOME_EXTENSIONS_DIR_LOCATION=/home/$USERNAME/.local/share/gnome-shell


SCRIPT_LOC=$(dirname $(readlink -f "${BASH_SOURCE:-$0}"))

cd $SCRIPT_LOC


echo "Trying to add some UI tweaks ..."

if ! [ -d "$NAUTILUS_SCRIPTS_LOCATION" ]; then
    mkdir -v -p $NAUTILUS_SCRIPTS_LOCATION
fi

if ! [ -d "$TEMPLATE_FILES_LOCATION" ]; then
    mkdir -v -p $TEMPLATE_FILES_LOCATION
fi

if ! [ -d "$GNOME_EXTENSIONS_DIR_LOCATION" ]; then
    mkdir -v -p $GNOME_EXTENSIONS_DIR_LOCATION
fi


echo "" > $TEMPLATE_FILES_LOCATION/txt-file

cp -v *.sh $NAUTILUS_SCRIPTS_LOCATION
#rm $NAUTILUS_SCRIPTS_LOCATION/install.sh

sudo apt install xclip -y

cp -v -R extensions $GNOME_EXTENSIONS_DIR_LOCATION


echo "Done!"
