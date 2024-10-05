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
cleanup_success=true

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

# Cleanup function
cleanup_snapshots() {
    echo "Starting cleanup process at $(date +"%Y-%m-%d %H:%M:%S")" >> "$LOG_FILE"

    if restic -r "$RESTIC_REPOSITORY" --password-file "$PASSWORD_FILE" forget --keep-last "$KEEP_SNAPSHOTS" --prune 2>>"$LOG_FILE"; then
        echo "Cleanup completed successfully at $(date +"%Y-%m-%d %H:%M:%S"). Kept the last $KEEP_SNAPSHOTS snapshots." >> "$LOG_FILE"
    else
        echo "Cleanup failed at $(date +"%Y-%m-%d %H:%M:%S"), see log for details." >> "$LOG_FILE"
        cleanup_success=false
    fi
}

# Function to summarize backup and cleanup, and send Telegram notification
operation_summary() {
    local end_time=$(date +"%Y-%m-%d %H:%M:%S")
    local message=""

    if $backup_success; then
        local backup_stats=$(restic -r "$RESTIC_REPOSITORY" --password-file "$PASSWORD_FILE" stats | awk '/Stats in restore-size mode:/,0')
        message+="🎉 Backup completed successfully at $end_time 🎉\n"
        message+="💾 Repository: $RESTIC_REPOSITORY\n"
        message+="🤖 Backup Stats:\n$backup_stats\n\n"
    else
        message+="❌ Backup failed at $end_time ❌\nCheck log $LOG_FILE for details.\n\n"
    fi

    if $cleanup_success; then
        local cleanup_stats=$(restic -r "$RESTIC_REPOSITORY" --password-file "$PASSWORD_FILE" stats | awk '/Stats in restore-size mode:/,0')
        message+="🧹 Cleanup completed successfully at $end_time\n"
        message+="Kept the last $KEEP_SNAPSHOTS snapshots.\n"
        message+="🤖 Cleanup Stats:\n$cleanup_stats\n"
    else
        message+="❌ Cleanup failed at $end_time ❌\nCheck log $LOG_FILE for details.\n"
    fi

    send_telegram "$message"
}

# Main execution
echo "Starting backup process at $(date +"%Y-%m-%d %H:%M:%S")" >> "$LOG_FILE"
backup

if ! $backup_success; then
    echo "Performing detailed check due to previous failures..." >> "$LOG_FILE"
    restic -r "$RESTIC_REPOSITORY" --password-file "$PASSWORD_FILE" check >> "$LOG_FILE" 2>&1
fi

echo "Starting cleanup process..." >> "$LOG_FILE"
cleanup_snapshots

# Send summary notification
operation_summary
