#!/bin/bash

clear

# Function to strip ANSI escape sequences
strip_ansi() {
    echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# Function to handle cleanup
cleanup() {
    echo "Cleaning up..."
    rm -f /tmp/fifo
    rm -f /tmp/upgrade_{core,aur,devel}
    rm -f /tmp/formatted_upgrades
    rm -f /tmp/{core,aur,devel}_upgrade_log
}

# Function to handle abort signal
abort_upgrade() {
    echo "Upgrade aborted."
    kill $PID >/dev/null 2>&1
    cleanup
    exit 1
}

# Set traps for various signals
trap 'abort_upgrade' SIGINT SIGTERM
trap 'cleanup' EXIT

# Function to get terminal dimensions and calculate dialog size
get_dialog_size() {
    local width_percentage=${1:-85}
    local height_percentage=${2:-85}

    term_width=$(tput cols)
    term_height=$(tput lines)
    dialog_width=$((term_width * width_percentage / 100))
    dialog_height=$((term_height * height_percentage / 100))
}

# Function to display menu using dialog
display_menu() {
    local menu_height=$1
    local menu_options=("${@:2}")

    dialog --clear --no-cancel --backtitle "PacJunkie" --title "Main Menu" --menu "Choose an option:" $menu_height 50 6 "${menu_options[@]}" 3>&1 1>&2 2>&3
}

# Function to center text in the terminal
center_text() {
    local text="$1"
    local stripped_text
    stripped_text=$(strip_ansi "$text")
    local term_width
    term_width=$(tput cols)
    local text_length=${#stripped_text}
    local padding=$(( (term_width - text_length) / 2 ))
    printf "%*s%s\n" $padding "" "$text"
}

# Function to display the title with animation
display_title() {
    clear
    local title
    title=$(toilet --metal -f crawford "PacJunkie")
    IFS=$'\n' read -r -d '' -a title_lines <<< "$title"
    local term_width
    term_width=$(tput cols)
    local term_height
    term_height=$(tput lines)
    local num_lines=${#title_lines[@]}
    local vertical_offset=$(( (term_height - num_lines) / 2 ))

    for line in "${title_lines[@]}"; do
        tput cup $vertical_offset 0
        center_text "$line"
        ((vertical_offset++))
    done

    local prompt="Press Enter"
    local prompt_length=${#prompt}
    local prompt_offset=$(( (term_width - prompt_length) / 2 ))

    tput cup $vertical_offset $prompt_offset
    printf "%s" "$prompt"

    read -rsn1
}

display_realtime_output() {
    local cmd="$1"
    local title="$2"
    local logfile="$3"
    
    get_dialog_size
    # Check if FIFO file exists and remove it
    [ -p /tmp/fifo ] && rm /tmp/fifo
    mkfifo /tmp/fifo
    
    # Set trap for abort signal
    trap 'abort_upgrade' SIGUSR1
    
    # Run the command, strip ANSI escape sequences, and feed the output to dialog
    $cmd > >(tee /tmp/fifo > "$logfile") 2>&1 &
    PID=$!

    dialog --title "$title" --programbox $dialog_height $dialog_width < <(sed -u -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" /tmp/fifo) &
    DIALOG_PID=$!

    while kill -0 $PID 2> /dev/null; do
        read -rsn1 -t 1 key
        if [[ $key == "A" || $key == "a" ]]; then
            kill -SIGUSR1 $$
        fi
    done
    
    wait $PID
    kill $DIALOG_PID > /dev/null 2>&1
    read -rsn1 key
    clear
}

# Function to display realtime output
display_realtime_output_nosize() {
    local cmd="$1"
    local title="$2"
    local logfile="$3"
    local dialog_height="$4"
    local dialog_width="$5"
    
    get_dialog_size
    mkfifo /tmp/fifo
    
    # Set trap for abort signal
    trap 'abort_upgrade' SIGUSR1
    
    # Run the command, strip ANSI escape sequences, and feed the output to dialog
    $cmd > >(tee /tmp/fifo > "$logfile") 2>&1 &
    PID=$!

    tail -f /tmp/fifo | dialog --title "$title" --no-ok --no-kill --programbox $4 $5 &
    DIALOG_PID=$!

    while kill -0 $PID 2> /dev/null; do
        read -rsn1 -t 1 key
        if [[ $key == "A" || $key == "a" ]]; then
            kill -SIGUSR1 $$
        fi
    done

    wait $PID
    rm /tmp/fifo
    kill $DIALOG_PID > /dev/null 2>&1
    clear
}

list_upgrades() {
    # Use display_realtime_output to check for upgrades
    display_realtime_output_nosize "yay -Qu --explicit" "Checking for Core Upgrades" "/tmp/upgrade_core" 3 0
    display_realtime_output_nosize "yay -Qu" "Checking for AUR Upgrades" "/tmp/upgrade_aur" 3 0
    display_realtime_output_nosize "yay -Qu --devel" "Checking for DEVEL Upgrades" "/tmp/upgrade_devel" 3 0

    # If any of the upgrade_* files are empty, put "no upgrades available" in the file
    for file in /tmp/upgrade_{core,aur,devel}; do
        if [ ! -s "$file" ]; then
            echo "no_upgrades_available" > "$file"
        fi
    done

    # Read upgrades from the temporary files
    core_upgrades=$(cat /tmp/upgrade_core)
    aur_upgrades=$(cat /tmp/upgrade_aur)
    devel_upgrades=$(cat /tmp/upgrade_devel)

    # Function to format upgrades
    format_upgrades() {
        local upgrades="$1"
        if [[ $upgrades != "no_upgrades_available" ]]; then
            echo "$upgrades" | awk '{if(NF==3){print $1, $2, $3}else{print $1, $2, "latest-commit"}}' | grep -Ev '^\->|^devel|^for' | column -t
        else
            echo "no_upgrades_available"
        fi
    }

    # Format upgrades for display
    local formatted_upgrades=""
    
    formatted_upgrades+="CORE:\n"
    formatted_upgrades+=$(format_upgrades "$core_upgrades")
    
    formatted_upgrades+="\n\nAUR:\n"
    formatted_upgrades+=$(format_upgrades "$aur_upgrades")
    
    formatted_upgrades+="\n\nDEVEL:\n"
    formatted_upgrades+=$(format_upgrades "$devel_upgrades")

    # Save the formatted upgrades to a file
    echo -e "$formatted_upgrades" > /tmp/formatted_upgrades

    # Show updates using whiptail
    get_dialog_size
    whiptail --title "Available Updates" --msgbox "$formatted_upgrades" $dialog_height $dialog_width

    # Clean up
    rm /tmp/upgrade_{core,aur,devel} /tmp/formatted_upgrades
}

# Function to update core system
upgrade_core() {
    display_realtime_output "yay -Syu --repo --noconfirm" "Upgrading Core System" "/tmp/core_upgrade_log"
}

# Function to update AUR packages
upgrade_aur() {
    display_realtime_output "yay -Syu --noconfirm" "Upgrading AUR Packages" "/tmp/aur_upgrade_log"
}

# Function to update development packages
upgrade_devel() {
    display_realtime_output "yay -Syu --devel --noconfirm" "Upgrading Development Packages" "/tmp/devel_upgrade_log"
}

# Function to update all packages
update_all() {
    display_realtime_output "yay -Syu --repo --noconfirm" "Upgrading Core Packages" "/tmp/core_upgrade_log"
    display_realtime_output "yay -Syu --noconfirm" "Upgrading AUR Packages" "/tmp/aur_upgrade_log"
    display_realtime_output "yay -Syu --devel --noconfirm" "Upgrading Development Packages" "/tmp/devel_upgrade_log" 
}

# Function to parse and format update logs
format_upgrade_log() {
    cat /tmp/core_upgrade_log /tmp/aur_upgrade_log /tmp/devel_upgrade_log > /tmp/combined_upgrade_log
    local log_file="$1"
    local section_title="$2"
    if [ -s "$log_file" ]; then
        echo "$section_title"
        grep -E "upgraded|installing|removing" "$log_file" | awk '{print $1, $3, "->", $5}'
        echo ""
    fi
}

# Function to calculate menu height dynamically
calculate_menu_height() {
    local num_items=$1
    local base_height=10
    local height=$((base_height + num_items))
    echo $height
}

# Main script execution
display_title
clear
while true; do
    # Clear any leftover processes
    killall -q yay dialog tee tail >/dev/null 2>&1

    # Define the menu options
    menu_options=(
        "1" "List available upgrades"
        "2" "Upgrade core system"
        "3" "Upgrade AUR packages"
        "4" "Upgrade devel packages"
        "5" "Upgrade all packages"
        "6" "Quit"
    )

    # Calculate menu height based on number of options
    menu_height=$(calculate_menu_height ${#menu_options[@]})

    # Display the menu and capture user choice
    CHOICE=$(display_menu $menu_height "${menu_options[@]}")

    # Handle user choice
    case $CHOICE in
        1) clear; list_upgrades ;;
        2) clear; upgrade_core ;;
        3) clear; upgrade_aur ;;
        4) clear; upgrade_devel ;;
        5) clear; update_all ;;
        6) break ;;
        *) clear; dialog --msgbox "Invalid option. Please try again." 10 40 ;;
    esac

    # Clear any leftover processes
    killall -q yay dialog tee tail >/dev/null 2>&1
done

clear
# Clear any leftover processes at the end
killall -q yay dialog tee tail >/dev/null 2>&1
cleanup
