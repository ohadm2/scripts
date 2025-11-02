#!/bin/bash

# Script to replace tint2 configurator with jgmenu

echo "Starting setup to replace tint2 configurator with jgmenu..."

# Step 1: Install jgmenu if not already installed
echo "Checking if jgmenu is installed..."
if ! command -v jgmenu &> /dev/null; then
    echo "jgmenu not found. Installing..."
    
    # Detect package manager
    if command -v apt &> /dev/null; then
        sudo apt update && sudo apt install -y jgmenu
    elif command -v pacman &> /dev/null; then
        sudo pacman -S --noconfirm jgmenu
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y jgmenu
    else
        echo "Unable to detect package manager. Please install jgmenu manually."
        exit 1
    fi
    
    echo "jgmenu installed successfully."
else
    echo "jgmenu is already installed."
fi

# Step 2: Create desktop entry for jgmenu
echo "Creating desktop entry for jgmenu..."
mkdir -p ~/.local/share/applications/

# Use a common system icon for the menu
ICON_PATH="/usr/share/icons/hicolor/scalable/apps/jgmenu.svg"
if [ ! -f "$ICON_PATH" ]; then
    ICON_PATH="/usr/share/icons/Papirus/16x16/apps/start-here.svg"
    if [ ! -f "$ICON_PATH" ]; then
        ICON_PATH="/usr/share/icons/hicolor/scalable/apps/start-here.svg"
        if [ ! -f "$ICON_PATH" ]; then
            ICON_PATH="/usr/share/icons/hicolor/scalable/places/start-here.svg"
        fi
    fi
fi

cat > ~/.local/share/applications/jgmenu.desktop << EOF
[Desktop Entry]
Name=Applications Menu
Comment=jgmenu application menu
Exec=jgmenu_run
Terminal=false
Type=Application
Icon=$ICON_PATH
Categories=System;Utility;
StartupNotify=false
EOF

echo "Desktop entry created at ~/.local/share/applications/jgmenu.desktop"

# Step 3: Configure jgmenu
echo "Configuring jgmenu to match tint2 appearance..."
mkdir -p ~/.config/jgmenu/

if [ ! -f ~/.config/jgmenu/jgmenurc ]; then
    # Initialize jgmenu if not already done
    jgmenu_run init
fi

# Configure jgmenu to match tint2 appearance
grep -q "tint2_look" ~/.config/jgmenu/jgmenurc
if [ $? -ne 0 ]; then
    echo "tint2_look = 1" >> ~/.config/jgmenu/jgmenurc
    echo "position_mode = pointer" >> ~/.config/jgmenu/jgmenurc
fi

echo "jgmenu configured to match tint2 appearance."

# Step 4: Modify tint2 configuration
echo "Modifying tint2 configuration..."

# Backup original tint2rc
TINT2_CONFIG="$HOME/.config/tint2/tint2rc"
TINT2_BACKUP="$HOME/.config/tint2/tint2rc.backup.$(date +%Y%m%d%H%M%S)"

if [ -f "$TINT2_CONFIG" ]; then
    cp "$TINT2_CONFIG" "$TINT2_BACKUP"
    echo "Backed up original tint2rc to $TINT2_BACKUP"
    
    # Check if panel_items exists and add Button plugin if not already there
    if grep -q "panel_items" "$TINT2_CONFIG"; then
        # Check if P (button) is already in panel_items
        if ! grep -q "panel_items.*P" "$TINT2_CONFIG"; then
            # Add P at the beginning of panel_items
            sed -i 's/panel_items = /panel_items = P/g' "$TINT2_CONFIG"
        fi
    else
        # Add panel_items line with P if it doesn't exist
        echo "panel_items = P" >> "$TINT2_CONFIG"
    fi
    
    # Check if button config already exists, if not add it
    if ! grep -q "button = new" "$TINT2_CONFIG"; then
        cat >> "$TINT2_CONFIG" << EOF

# Button for jgmenu
button = new
button_icon = $ICON_PATH
button_lclick_command = jgmenu_run
button_rclick_command = jgmenu_run
button_text = 
button_tooltip = Applications Menu
button_max_icon_size = 22
button_padding = 2 2
button_background_id = 0
button_centered = 0
button_font = sans 9
EOF
    else
        # Update existing button configuration
        sed -i '/button_lclick_command/c\button_lclick_command = jgmenu_run' "$TINT2_CONFIG"
        sed -i '/button_icon/c\button_icon = '"$ICON_PATH" "$TINT2_CONFIG"
    fi
    
    # Set startup notifications to 0
    if grep -q "startup_notifications" "$TINT2_CONFIG"; then
        sed -i 's/startup_notifications = .*/startup_notifications = 0/g' "$TINT2_CONFIG"
    else
        echo "startup_notifications = 0" >> "$TINT2_CONFIG"
    fi
    
    echo "tint2 configuration updated successfully."
else
    echo "Error: tint2 configuration file not found at $TINT2_CONFIG"
    exit 1
fi

# Step 5: Restart tint2 to apply changes
echo "Restarting tint2 to apply changes..."
killall -SIGUSR1 tint2 || (killall tint2 && tint2 &)

echo "All done! The tint2 configurator icon has been replaced with jgmenu."
echo "You can customize jgmenu by editing ~/.config/jgmenu/jgmenurc"
echo "If tint2 doesn't restart automatically, please restart it manually."

