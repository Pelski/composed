#!/bin/bash

# Configuration
DEPLOYMENT_ENV=":apple: Production"      # Deployment environment (used only in Discord message)
DEPLOYMENTS_DIR="/my-deployment-dir"     # Directory with Docker Compose files (best solution /deployment/<service_name>/docker-compose.yml)
DISCORD_WEBHOOK_URL=""                   # Discord Webhook URL (leave empty if you don't want to use it)
DOCKER_COMPOSE="/usr/bin/docker compose" # Docker Compose binary (try with '-' if it doesn't work)
GIT="/usr/bin/git"                       # Git binary
LOCK_FILE="/tmp/.composed.lock"          # Lock file location (prevents errors on long tasks)

# ================================================

# Logging function
log_message() {
  local message=$1
  local current_time=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$current_time] > $message"
}

# Function to send Discord notification
send_discord_notification() {
  local message=$1
  if [ -n "$DISCORD_WEBHOOK_URL" ]; then
    curl -H "Content-Type: application/json" -X POST -d "{\"content\": \"$message\"}" "$DISCORD_WEBHOOK_URL"
  fi
}

# Function to get image versions for a service
get_image_versions() {
  local service_name=$1
  $DOCKER_COMPOSE images | grep "$service_name" | awk '{print $2}'
}

# Function to check if any container is running
is_container_running() {
  if [[ -n "$($DOCKER_COMPOSE --log-level ERROR ps -q)" ]]; then
    return 0
  else
    return 1
  fi
}

# Navigate to deployment directory
cd $DEPLOYMENTS_DIR || exit 1

# Create lock file if it doesn't exist
if [ -e "$LOCK_FILE" ]; then
  log_message "Lock file exists. Exiting."
  exit 1
else
  touch "$LOCK_FILE"
fi

# Ensure lock file is removed on exit
trap 'rm -f "$LOCK_FILE"' EXIT

# Get current commit hash
previous_commit_sha=$($GIT rev-parse HEAD)
log_message "Current commit hash: $previous_commit_sha"

# Pull latest changes from the repository
git_output=$($GIT pull)
if [[ $git_output == *"Already up to date."* ]]; then
  log_message "No changes found."
  exit 0
fi
current_commit_sha=$($GIT rev-parse HEAD)
log_message "New commit hash: $current_commit_sha"

# Get changed docker-compose files
changed_files=$($GIT diff --name-only $previous_commit_sha $current_commit_sha | grep -E "docker-compose.ya?ml")
if [ -z "$changed_files" ]; then
  log_message "No docker-compose files have changed."
  exit 0
fi

# Iterate through changed files and restart services
IFS=$'\n' read -rd '' -a changed_files_array <<<"$changed_files"
updated_services=()

for file in "${changed_files_array[@]}"; do
  service_dir=$(dirname "$file")
  cd "$DEPLOYMENTS_DIR/$service_dir" || exit 1
  service_name=$(basename "$service_dir")

  log_message "Reloading service: $service_name"
  running_before_restart=false
  if is_container_running; then
    log_message "Service $service_name is running."
    running_before_restart=true
  else
    log_message "Service $service_name is not running."
  fi

  log_message "Pulling images for $service_name..."
  $DOCKER_COMPOSE pull

  log_message "Stopping $service_name..."
  $DOCKER_COMPOSE down

  if head -n 1 docker-compose.yml 2>/dev/null | grep -q "#disabled" || head -n 1 docker-compose.yaml 2>/dev/null | grep -q "#disabled"; then
    log_message "Service $service_name is disabled"
    updated_services+=("\n- :red_square:  $service_name (stopped)")
    continue
  fi

  log_message "Starting $service_name..."
  $DOCKER_COMPOSE up -d

  if $running_before_restart; then
    updated_services+=("\n- :blue_square:  $service_name (restarted)")
  else
    updated_services+=("\n- :green_square:  $service_name (started)")
  fi
done

# Log and send notification about the completed deployment
log_message "Deployment completed for updated services."
if [ ${#updated_services[@]} -eq 0 ]; then
  log_message "No services were updated."
else
  current_date=$(date '+%H:%M %d.%m.%Y')

  send_discord_notification "## $DEPLOYMENT_ENV\n\n**Service status changes:**${updated_services[*]}\n"
  log_message "Deployment completed for updated services: ${updated_services[*]}"
fi
