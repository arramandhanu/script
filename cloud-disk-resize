#!/bin/bash

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Log file path
LOG_FILE="resize_cloud_disk.log"

# Function to log messages
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Function to send notifications
notify() {
    MESSAGE=$1
    if command -v notify-send &>/dev/null; then
        notify-send "Cloud Disk Resizer" "$MESSAGE"
    elif command -v osascript &>/dev/null; then
        osascript -e "display notification \"$MESSAGE\" with title \"Cloud Disk Resizer\""
    fi
}

# Function to validate integer input
validate_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && return 0 || return 1
}

# Function to display header
display_header() {
    log "${CYAN}=========================================${RESET}"
    log "${YELLOW}   🚀 Cloud Disk Resizer (AWS/GCP)      ${RESET}"
    log "${CYAN}=========================================${RESET}"
}

# Main Menu
while true; do
    display_header
    log "${BLUE}1) Select Cloud Provider (AWS/GCP)${RESET}"
    log "${BLUE}2) Enter Disk/Volume ID${RESET}"
    log "${BLUE}3) Enter New Size (GB)${RESET}"
    log "${BLUE}4) Enable/Disable Dry-Run Mode${RESET}"
    log "${BLUE}5) Start Resize Process${RESET}"
    log "${BLUE}6) Exit${RESET}"
    log "${CYAN}=========================================${RESET}"
    read -p "👉 Enter your choice (1-6): " choice

    case $choice in
        1)
            log "${YELLOW}🌍 Select Cloud Provider:${RESET}"
            log "${GREEN}1) AWS${RESET}"
            log "${GREEN}2) GCP${RESET}"
            read -p "👉 Enter choice (1 or 2): " provider_choice
            if [[ "$provider_choice" == "1" ]]; then
                CLOUD_PROVIDER="AWS"
                log "${GREEN}✅ AWS selected.${RESET}"
            elif [[ "$provider_choice" == "2" ]]; then
                CLOUD_PROVIDER="GCP"
                log "${GREEN}✅ GCP selected.${RESET}"
            else
                log "${RED}❌ Invalid choice. Please enter 1 or 2.${RESET}"
            fi
            ;;
        2)
            if [[ "$CLOUD_PROVIDER" == "AWS" ]]; then
                read -p "🔹 Enter AWS EBS Volume ID (e.g., vol-xxxxxxxx): " VOLUME_ID
                log "${GREEN}✅ AWS Volume ID saved: $VOLUME_ID${RESET}"
            elif [[ "$CLOUD_PROVIDER" == "GCP" ]]; then
                read -p "🔹 Enter GCP Disk Name: " DISK_NAME
                read -p "🔹 Enter GCP Zone (e.g., us-central1-a): " GCP_ZONE
                log "${GREEN}✅ GCP Disk details saved: $DISK_NAME in $GCP_ZONE${RESET}"
            else
                log "${RED}❌ Please select a cloud provider first.${RESET}"
            fi
            ;;
        3)
            read -p "🔹 Enter new size in GB: " NEW_SIZE
            if validate_integer "$NEW_SIZE"; then
                log "${GREEN}✅ Valid size: $NEW_SIZE GB.${RESET}"
            else
                log "${RED}❌ Invalid size. Please enter a number.${RESET}"
            fi
            ;;
        4)
            if [[ "$DRY_RUN" == "true" ]]; then
                DRY_RUN="false"
                log "${YELLOW}🔴 Dry-Run Mode Disabled.${RESET}"
            else
                DRY_RUN="true"
                log "${GREEN}🟢 Dry-Run Mode Enabled.${RESET}"
            fi
            ;;
        5)
            if [[ "$CLOUD_PROVIDER" == "AWS" && -n "$VOLUME_ID" && -n "$NEW_SIZE" ]]; then
                log "${YELLOW}🔄 Resizing AWS EBS Volume $VOLUME_ID to $NEW_SIZE GB...${RESET}"
                notify "Resizing AWS EBS Volume $VOLUME_ID to $NEW_SIZE GB"

                if [[ "$DRY_RUN" == "true" ]]; then
                    log "${CYAN}🛑 Dry-Run: Would execute AWS resize command here.${RESET}"
                else
                    aws ec2 modify-volume --volume-id "$VOLUME_ID" --size "$NEW_SIZE" | tee -a "$LOG_FILE"
                fi

                log "${BLUE}⏳ Waiting for resize operation to complete...${RESET}"
                while [ "$(aws ec2 describe-volumes-modifications \
                    --volume-id "$VOLUME_ID" \
                    --filters Name=modification-state,Values="optimizing","completed" \
                    --query "length(VolumesModifications)" --output text)" != "1" ]; do
                    sleep 2
                    log "${YELLOW}⌛ Still resizing...${RESET}"
                done
                log "${GREEN}✅ Resize operation completed.${RESET}"
                notify "AWS EBS Volume resized successfully!"

            elif [[ "$CLOUD_PROVIDER" == "GCP" && -n "$DISK_NAME" && -n "$GCP_ZONE" && -n "$NEW_SIZE" ]]; then
                log "${YELLOW}🔄 Resizing GCP Disk $DISK_NAME to $NEW_SIZE GB in zone $GCP_ZONE...${RESET}"
                notify "Resizing GCP Disk $DISK_NAME to $NEW_SIZE GB"

                if [[ "$DRY_RUN" == "true" ]]; then
                    log "${CYAN}🛑 Dry-Run: Would execute GCP resize command here.${RESET}"
                else
                    gcloud compute disks resize "$DISK_NAME" --size "$NEW_SIZE" --zone "$GCP_ZONE" | tee -a "$LOG_FILE"
                fi

                log "${GREEN}✅ GCP disk resize operation completed.${RESET}"
                notify "GCP Disk resized successfully!"
            else
                log "${RED}❌ Missing information. Ensure cloud provider, disk ID, and size are set.${RESET}"
            fi
            ;;
        6)
            log "${GREEN}🚀 Exiting... Goodbye!${RESET}"
            exit 0
            ;;
        *)
            log "${RED}❌ Invalid choice. Please enter a number between 1 and 6.${RESET}"
            ;;
    esac
done
