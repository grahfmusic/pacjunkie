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
  kill "$PID" >/dev/null 2>&1
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

# generate title screen
display_title() {
    clear
    local title
    title=$(toilet --metal -f crawford "PacJunkie" && echo -e "\e[36mVersion\e[0m 0.5 :: \e[36mCreated by\e[0m Grahf 2024 :: \e[36mgithub.com\e[0m/grahfmusic\n\n")
    IFS=$'\n' read -r -d '' -a title_lines <<<"$title"
    
    local term_width
    term_width=$(tput cols)
    local term_height
    term_height=$(tput lines)
    
    local num_lines=${#title_lines[@]}
    local vertical_offset=$(((term_height - num_lines) / 2))
    
    for line in "${title_lines[@]}"; do
        tput cup $vertical_offset 0
        center_text "$line"
        ((vertical_offset++))
    done
    
    # Add a line break after displaying the title
    ((vertical_offset++))
    
    local prompt="Press Enter"
    local prompt_length=${#prompt}
    local prompt_offset=$(((term_width - prompt_length) / 2))
    
    tput cup $vertical_offset $prompt_offset
    printf "%s" "$prompt"
    
    read -rsn1
}

# Function to display menu using dialog
display_menu() {
  local menu_height=$1
  local menu_options=("${@:2}")

  dialog --clear --no-cancel --backtitle "PacJunkie" --title "Main Menu" --menu "Choose an option:" "$menu_height" 50 6 "${menu_options[@]}" 3>&1 1>&2 2>&3
}

# Function to center text in the terminal
center_text() {
  local text="$1"
  local stripped_text
  stripped_text=$(strip_ansi "$text")
  local term_width
  term_width=$(tput cols)
  local text_length=${#stripped_text}
  local padding=$(((term_width - text_length) / 2))
  printf "%*s%s\n" $padding "" "$text"
}

# Function to display the title with animation

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
  $cmd > >(tee /tmp/fifo >"$logfile") 2>&1 &
  PID=$!

  dialog --title "$title" --programbox "$dialog_height" "$dialog_width" < <(sed -u -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" /tmp/fifo) &
  DIALOG_PID=$!

  while kill -0 $PID 2>/dev/null; do
    read -rsn1 -t 1 key
    if [[ $key == "A" || $key == "a" ]]; then
      kill -SIGUSR1 $$
    fi
  done

  wait $PID
  kill $DIALOG_PID >/dev/null 2>&1
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
  $cmd > >(tee /tmp/fifo >"$logfile") 2>&1 &
  PID=$!

  tail -f /tmp/fifo | dialog --title "$title" --no-ok --no-kill --programbox "$4" "$5" &
  DIALOG_PID=$!

  while kill -0 $PID 2>/dev/null; do
    read -rsn1 -t 1 key
    if [[ $key == "A" || $key == "a" ]]; then
      kill -SIGUSR1 $$
    fi
  done

  wait $PID
  rm /tmp/fifo
  kill $DIALOG_PID >/dev/null 2>&1
  clear
}

# Function to center a block of text within a given width
center_block() {
  local total_width="$1"
  local content_width="$2"
  local padding=$(((total_width - content_width) / 2))

  while IFS= read -r line; do
    printf "%*s%s\n" "$padding" "" "$line"
  done
}

# Function to calculate the maximum lengths of the package, current version, and upgradable version
calculate_max_lengths() {
  while IFS= read -r line; do
    package=$(echo "$line" | awk '{print $1}')
    current_version=$(echo "$line" | awk '{print $2}')
    upgradable_version=$(echo "$line" | awk '{print $3}')
    [ ${#package} -gt $max_package_length ] && max_package_length=${#package}
    [ ${#current_version} -gt $max_current_version_length ] && max_current_version_length=${#current_version}
    [ ${#upgradable_version} -gt $max_upgradable_version_length ] && max_upgradable_version_length=${#upgradable_version}
  done <"$1"
}

# Function to display progress bar
display_progress_bar() {
  local title="$1"
  local cmd="$2"
  local step="$3"
  local total_steps="$4"
  local logfile="$5"
  local increment=$((100 / total_steps))

  ( $cmd >"$logfile" 2>&1 ) &
  PID=$!

  (
    progress=$((increment * (step - 1)))
    while kill -0 $PID 2>/dev/null; do
      echo $progress
      progress=$((progress + 1))
      if [ $progress -gt $((increment * step)) ]; then
        progress=$((increment * step))
      fi
      sleep 1
    done
    echo $((increment * step))
  ) | dialog --title "$title" --gauge "Please wait..." 0 40

  wait $PID
}



# Function to list upgrades
list_upgrades() {
  # Initialize maximum lengths
  max_package_length=0
  max_current_version_length=0
  max_upgradable_version_length=0

  # Total steps for progress bar
  total_steps=4

  # Use display_progress_bar to check for upgrades with progress bar
  display_progress_bar "Updating Repositories" "sudo pacman -Sy" 1 $total_steps "/tmp/updating_repos"
  display_progress_bar "Checking for Core Upgrades" "sudo pacman -Qu" 2 $total_steps "/tmp/upgrade_core"
  display_progress_bar "Checking for AUR Upgrades" "yay -Qua --aur" 3 $total_steps "/tmp/upgrade_aur"
  display_progress_bar "Checking for DEVEL Upgrades" "yay -Qu --devel" 4 $total_steps "/tmp/upgrade_devel"

  # Remove duplicates from devel that exist in core
  if [ -s /tmp/upgrade_core ]; then
    awk 'NR==FNR {a[$1]; next} !($1 in a)' /tmp/upgrade_core /tmp/upgrade_devel > /tmp/upgrade_devel_filtered
  else
    cp /tmp/upgrade_devel /tmp/upgrade_devel_filtered
  fi
  mv /tmp/upgrade_devel_filtered /tmp/upgrade_devel

  # Calculate max lengths for all files
  calculate_max_lengths "/tmp/upgrade_core"
  calculate_max_lengths "/tmp/upgrade_aur"
  calculate_max_lengths "/tmp/upgrade_devel"

  # Add extra padding
  max_package_length=$((max_package_length + 5))
  max_current_version_length=$((max_current_version_length + 5))
  max_upgradable_version_length=$((max_upgradable_version_length + 5))
  get_dialog_size
  dialog_width=$dialog_width

  # Calculate total width for the separator line
  total_width=$((max_package_length + max_current_version_length + max_upgradable_version_length + 4)) # Add four spaces for separation

  # Create the header
  header="\n\n"
  header+="Package$(printf ' %.0s' $(seq 1 $((max_package_length - 7))))"
  header+=" Current Version$(printf ' %.0s' $(seq 1 $((max_current_version_length - 15))))"
  header+=" Upgradable Version"

  # Format and display upgrades using dialog
  {
    echo -e "$header"
    echo $(printf '%.0s─' $(seq 1 $total_width))
    echo "CORE:"
    process_file "/tmp/upgrade_core"
    echo $(printf '%.0s─' $(seq 1 $total_width))
    echo "AUR:"
    process_file "/tmp/upgrade_aur"
    echo $(printf '%.0s─' $(seq 1 $total_width))
    echo "DEVEL:"
    process_file "/tmp/upgrade_devel"
    echo $(printf '%.0s─' $(seq 1 $total_width))
  } >/tmp/formatted_upgrades

  center_block "$dialog_width" "$total_width" </tmp/formatted_upgrades >/tmp/centered_upgrades

  # Show updates 
  get_dialog_size

  # Get the actual height of the centered upgrades content
  actual_height=$(wc -l < /tmp/centered_upgrades)
  padded_height=$((actual_height + 6))
  if [[ $padded_height -lt $dialog_height ]]; then
    dialog_height=$padded_height
  fi

  dialog --title "Available Upgrades" --textbox /tmp/centered_upgrades $dialog_height $dialog_width

  # Clean up
  rm /tmp/upgrade_{core,aur,devel} /tmp/formatted_upgrades
}


# Function to update core system
upgrade_core() {
  display_realtime_output "sudo pacman -Syu --noconfirm --overwrite '*'" "Upgrading Core System" "/tmp/core_upgrade_log"
}

# Function to update AUR packages
upgrade_aur() {
  display_realtime_output "yay -Sua --aur --noconfirm --overwrite '*'" "Upgrading AUR Packages" "/tmp/aur_upgrade_log"
}

# Function to update development packages
upgrade_devel() {
  display_realtime_output "yay -Syu --devel --noconfirm --timeupdate --rebuildall --overwrite '*'" "Upgrading Development Packages" "/tmp/devel_upgrade_log"
}

# Function to upgrade all packages
update_all() {
  display_realtime_output "sudo pacman -Syu --noconfirm --overwrite '*'" "Upgrading Core Packages" "/tmp/core_upgrade_log"
  display_realtime_output "yay -Sua --aur --noconfirm --overwrite '*'" "Upgrading AUR Packages" "/tmp/aur_upgrade_log"
  display_realtime_output "yay -Syu --devel --noconfirm --timeupdate --overwrite '*'" "Upgrading Development Packages" "/tmp/devel_upgrade_log"
}

# Function to parse and format update logs
format_upgrade_log() {
  cat /tmp/core_upgrade_log /tmp/aur_upgrade_log /tmp/devel_upgrade_log >/tmp/combined_upgrade_log
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

# Function to calculate max lengths for columns
calculate_max_lengths() {
  local input_file="$1"

  while IFS= read -r line; do
    if [[ "$line" == *"->"* ]]; then
      package_and_current_version=$(echo "$line" | awk -F '->' '{print $1}' | xargs)
      upgradable_version=$(echo "$line" | awk -F '->' '{print $2}' | xargs)

      if [[ -n "$package_and_current_version" && -n "$upgradable_version" ]]; then
        package=$(echo "$package_and_current_version" | grep -oE '^[a-zA-Z0-9._-]+')
        current_version=$(echo "$package_and_current_version" | sed "s/^$package //")

        # Update max lengths
        ((${#package} > max_package_length)) && max_package_length=${#package}
        ((${#current_version} > max_current_version_length)) && max_current_version_length=${#current_version}
        ((${#upgradable_version} > max_upgradable_version_length)) && max_upgradable_version_length=${#upgradable_version}
      fi
    fi
  done <"$input_file"
}

# Function to process and print the formatted output
process_file() {
  local input_file="$1"

  # Second pass to print the formatted output
  while IFS= read -r line; do
    if [[ "$line" == *"->"* ]]; then
      package_and_current_version=$(echo "$line" | awk -F '->' '{print $1}' | xargs)
      upgradable_version=$(echo "$line" | awk -F '->' '{print $2}' | xargs)

      if [[ -n "$package_and_current_version" && -n "$upgradable_version" ]]; then
        package=$(echo "$package_and_current_version" | grep -oE '^[a-zA-Z0-9._-]+')
        current_version=$(echo "$package_and_current_version" | sed "s/^$package //")

        printf "%-${max_package_length}s %-${max_current_version_length}s %-${max_upgradable_version_length}s\n" "$package" "$current_version" "$upgradable_version"
      fi
    fi
  done <"$input_file"
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
  CHOICE=$(display_menu "$menu_height" "${menu_options[@]}")

  # Handle user choice
  case $CHOICE in
  1)
    clear
    list_upgrades
    ;;
  2)
    clear
    upgrade_core
    ;;
  3)
    clear
    upgrade_aur
    ;;
  4)
    clear
    upgrade_devel
    ;;
  5)
    clear
    update_all
    ;;
  6) break ;;
  *)
    clear
    dialog --msgbox "Invalid option. Please try again." 10 40
    ;;
  esac

  # Clear any leftover processes
  killall -q yay dialog tee tail >/dev/null 2>&1
done

clear
# Clear any leftover processes at the end
killall -q yay dialog tee tail >/dev/null 2>&1
cleanup