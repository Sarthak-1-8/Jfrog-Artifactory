#!/bin/bash
set -euo pipefail

#######################################
# GLOBAL CONFIG
#######################################
CONFIG_FILE="./cleanup.conf"
LOG_FILE="$HOME/log/artifactory-cleanup.log"
DRY_RUN=true   # change to false to enable deletion

#######################################
# FUNCTIONS
#######################################
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE" || true
}

fail() {
  log "ERROR: $1"
  exit 1
}

check_prereqs() {
  command -v jf >/dev/null || fail "jf CLI not installed"
  command -v jq >/dev/null || fail "jq not installed"
  jf rt ping &>/dev/null || fail "Cannot connect to Artifactory"
}

repo_exists() {
  local repo="$1"
  local response
  
  # Get the response from the API
  response=$(jf rt curl -s "api/repositories/$repo" 2>&1)
  
  # Check if response contains an error
  if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    # Response has errors field, repo doesn't exist
    return 1
  fi
  
  # Check if response has a 'key' field (valid repo response)
  if echo "$response" | jq -e '.key' >/dev/null 2>&1; then
    # Valid repository response
    return 0
  fi
  
  # If we can't determine, assume it doesn't exist
  return 1
}

#######################################
# START
#######################################

mkdir -p "$(dirname "$LOG_FILE")"

log "===== Artifactory Cleanup Job Started ====="

[[ -f "$CONFIG_FILE" ]] || fail "Config file not found: $CONFIG_FILE"

check_prereqs

#######################################
# READ CONFIG
#######################################
while IFS=',' read -r REPO RETENTION_DAYS KEEP_LAST_N; do
  # Skip comments and empty lines
  [[ -z "$REPO" || "$REPO" =~ ^# ]] && continue

  # Trim whitespace
  REPO=$(echo "$REPO" | xargs)
  RETENTION_DAYS=$(echo "$RETENTION_DAYS" | xargs)
  KEEP_LAST_N=$(echo "$KEEP_LAST_N" | xargs)

  log "Processing repo: $REPO | Retention: $RETENTION_DAYS days | Keep Last: $KEEP_LAST_N"

  if ! repo_exists "$REPO"; then
    log "WARNING: Repository '$REPO' does not exist. Skipping."
    continue
  fi

  if [[ ! "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    log "WARNING: Invalid retention value '$RETENTION_DAYS' for repo '$REPO'. Skipping."
    continue
  fi

  if [[ ! "$KEEP_LAST_N" =~ ^[0-9]+$ ]]; then
    log "WARNING: Invalid keep_last_n value '$KEEP_LAST_N' for repo '$REPO'. Skipping."
    continue
  fi

  #######################################
  # AQL QUERY - Get ALL old files
  #######################################
  AQL_QUERY=$(cat <<EOF
items.find({
  "repo": "$REPO",
  "type": "file",
  "modified": { "\$before": "${RETENTION_DAYS}d" },
  "@retain": { "\$ne": "true" }
}).sort({ "\$desc": ["modified"] })
EOF
)

  # Suppress curl progress with -s flag
  RESULTS=$(jf rt curl -s -XPOST api/search/aql \
    -H "Content-Type: text/plain" \
    -d "$AQL_QUERY" 2>&1)

  # Check if results are valid JSON
  if ! echo "$RESULTS" | jq empty 2>/dev/null; then
    log "WARNING: Invalid JSON response for repo '$REPO'. Skipping."
    continue
  fi

  # Get total count of old files
  TOTAL_FILES=$(echo "$RESULTS" | jq -r '.range.total // 0')
  
  if [[ "$TOTAL_FILES" -eq 0 ]]; then
    log "No files older than $RETENTION_DAYS days found in repo '$REPO'"
    continue
  fi

  log "Found $TOTAL_FILES files older than $RETENTION_DAYS days in repo '$REPO'"

  # Calculate how many files to delete (total - keep_last_n)
  if [[ "$TOTAL_FILES" -le "$KEEP_LAST_N" ]]; then
    log "All $TOTAL_FILES files are protected (keeping last $KEEP_LAST_N). Nothing to delete."
    continue
  fi

  FILES_TO_DELETE=$((TOTAL_FILES - KEEP_LAST_N))
  log "Will process $FILES_TO_DELETE files for deletion (protecting newest $KEEP_LAST_N)"

  # Use mapfile to get files with proper path format
  mapfile -t ALL_FILES < <(echo "$RESULTS" | jq -r \
    '.results[] | 
    if .path == "." then
      .repo + "/" + .name
    else
      .repo + "/" + .path + "/" + .name
    end')

  DELETED_COUNT=0
  PROTECTED_COUNT=0
  
  # Get the array length
  ARRAY_LENGTH=${#ALL_FILES[@]}
  log "Array contains $ARRAY_LENGTH files to process"

  # Process each file
  for i in $(seq 0 $((ARRAY_LENGTH - 1))); do
    FILE="${ALL_FILES[$i]}"
    
    # Skip empty entries
    if [[ -z "$FILE" ]]; then
      continue
    fi

    # Protect the first KEEP_LAST_N files (newest ones)
    if [[ $i -lt $KEEP_LAST_N ]]; then
      log "Protecting recent file [$((i+1))/$TOTAL_FILES]: $FILE"
      PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
      continue
    fi

    # Delete the rest
    if [[ "$DRY_RUN" == true ]]; then
      log "[DRY-RUN] Would delete [$((i+1))/$TOTAL_FILES]: $FILE"
      DELETED_COUNT=$((DELETED_COUNT + 1))
    else
      log "Deleting [$((i+1))/$TOTAL_FILES]: $FILE"
      if jf rt del "$FILE" --quiet >/dev/null 2>&1; then
        DELETED_COUNT=$((DELETED_COUNT + 1))
        log "Successfully deleted: $FILE"
      else
        EXIT_CODE=$?
        log "WARNING: Failed to delete $FILE (exit code: $EXIT_CODE)"
      fi
    fi
  done

  log "Repo '$REPO' summary: Protected=$PROTECTED_COUNT, Deleted/Would delete=$DELETED_COUNT"

done < "$CONFIG_FILE"

log "===== Artifactory Cleanup Job Completed ====="