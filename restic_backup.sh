#!/bin/bash

source backup.conf

# Check for required commands
for cmd in restic curl hostname; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: Required command '$cmd' not found. Exiting."
        exit 1
    fi
done

export RCLONE_TRANSFERS=$RCLONE_TRANSFERS
export RCLONE_CHECKERS=$RCLONE_CHECKERS

backup_success=true

# Function to send Telegram notification
send_telegram() {
    local message=$1
    if [[ -z "$TELEGRAM_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        echo "Telegram token or chat ID not set. Skipping notification."
        return 1
    fi
    if ! curl -s -X POST https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage -d chat_id=$TELEGRAM_CHAT_ID -d text="$message" > /dev/null; then
        echo "Warning: Failed to send Telegram notification."
    fi
}

# Backup function with retry logic
backup() {
    local retries=2
    local delay=10  # Initial retry delay in seconds
    local attempt=0

    while [ $attempt -le $retries ]; do
        local start_time=$(date +%s)
        echo "Starting backup at $start_time, attempt $((attempt+1))" >> "$LOG_FILE"

        if restic -r "$RESTIC_REPOSITORY" --password-file "$PASSWORD_FILE" backup --files-from "$FILES_FROM" --exclude-file="$EXCLUDE_FILE" --tag "$BACKUP_TAG" >> "$LOG_FILE" 2>&1; then
            local end_time=$(date +%s)
            echo "Backup completed successfully at $end_time. Duration: $((end_time - start_time)) seconds." >> "$LOG_FILE"
            return 0
        else
            local end_time=$(date +%s)
            echo "Backup failed, attempt $((attempt+1)) at $end_time. Check log $LOG_FILE for details." >> "$LOG_FILE"
            attempt=$((attempt + 1))
            sleep $delay
            delay=$((delay * 2))  # Exponential backoff
        fi
    done

    echo "Backup failed after $retries retries at $(date +%Y-%m-%d\ %H:%M:%S)." >> "$LOG_FILE"
    backup_success=false
}


# Retrieve hostname and IP address
HOSTNAME=$(hostname)
IP_ADDRESS=$(curl -4 -s ip.sb)

# Function to summarize backup operation and send Telegram notification
backup_summary() {
    local end_time=$(date +"%Y-%m-%d %H:%M:%S")
    if $backup_success; then
        local stats_output=$(restic -r "$RESTIC_REPOSITORY" --password-file "$PASSWORD_FILE" stats | awk '/Stats in restore-size mode:/,0')
        echo "All backups completed successfully at $end_time" >> "$LOG_FILE"
        send_telegram "🎉 Backup completed successfully at $end_time 🎉
🖥️ Hostname: $HOSTNAME
🌐 IP Address: $IP_ADDRESS
💾 Repository: $RESTIC_REPOSITORY
🤖 Repository Stats: 

$stats_output"
    else
        echo "One or more backups failed at $end_time, see log $LOG_FILE for details." >> "$LOG_FILE"
        send_telegram "❌ Backup failed at $end_time ❌
🖥️ Hostname: $HOSTNAME
🌐 IP Address: $IP_ADDRESS
💾 Repository: $RESTIC_REPOSITORY
Check log $LOG_FILE for details."
    fi
}

echo "Starting backup process at $(date +"%Y-%m-%d %H:%M:%S")" >> "$LOG_FILE"

backup

if ! $backup_success; then
    echo "Performing detailed check due to previous failures..." >> "$LOG_FILE"
    restic -r "$RESTIC_REPOSITORY" --password-file "$PASSWORD_FILE" check >> "$LOG_FILE" 2>&1
    send_telegram "Restic repository check performed due to backup failure. Check log $LOG_FILE for details."
else
    echo "Skipping detailed check as all backups were successful." >> "$LOG_FILE"
fi

backup_summary