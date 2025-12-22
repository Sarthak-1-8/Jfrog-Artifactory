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

path_exists() {
  local path="$1"
  local response
  
  # Try to get folder info (works for both repos and folders)
  response=$(jf rt curl -s "api/storage/$path" 2>&1)
  
  # Check if response contains an error
  if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    return 1
  fi
  
  # Check if response has valid fields
  if echo "$response" | jq -e '.repo' >/dev/null 2>&1; then
    return 0
  fi
  
  return 1
}

get_folder_modified_date() {
  local path="$1"
  
  # AQL query to find the most recently modified file in this folder and all subfolders
  local aql_query=$(cat <<EOF
items.find({
  "path": { "\$match": "${path}*" },
  "type": "file"
}).include("repo", "path", "name", "modified").sort({ "\$desc": ["modified"] }).limit(1)
EOF
)
  
  local result=$(jf rt curl -s -XPOST api/search/aql \
    -H "Content-Type: text/plain" \
    -d "$aql_query" 2>&1)
  
  # Get the modified date of the most recent file
  local modified_date=$(echo "$result" | jq -r '.results[0].modified // empty')
  
  if [[ -n "$modified_date" ]]; then
    echo "$modified_date"
    return 0
  fi
  
  return 1
}

is_older_than_days() {
  local modified_date="$1"
  local retention_days="$2"
  
  # Convert modified date to epoch (remove milliseconds and timezone)
  local modified_epoch=$(date -d "${modified_date%.*}" +%s 2>/dev/null || echo "0")
  
  if [[ "$modified_epoch" -eq 0 ]]; then
    return 1
  fi
  
  # Calculate cutoff date
  local cutoff_epoch=$(date -d "$retention_days days ago" +%s)
  
  # Return 0 (true) if modified date is older than cutoff
  [[ "$modified_epoch" -lt "$cutoff_epoch" ]]
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
line_number=0
while read -r line; do
  line_number=$((line_number + 1))
  
  # Skip comments and empty lines
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  
  # Trim leading/trailing whitespace
  line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  # Skip if still empty after trim
  [[ -z "$line" ]] && continue
  
  # Check that line contains exactly 2 commas
  comma_count=$(echo "$line" | tr -cd ',' | wc -c)
  if [[ "$comma_count" -ne 2 ]]; then
    log "WARNING: Line $line_number has $comma_count commas (expected 2). Skipping: $line"
    continue
  fi
  
  # Split the line by comma
  REPO_PATH=$(echo "$line" | cut -d',' -f1 | xargs)
  RETENTION_DAYS=$(echo "$line" | cut -d',' -f2 | xargs)
  KEEP_LAST_N=$(echo "$line" | cut -d',' -f3 | xargs)
  
  # Check for spaces in REPO_PATH
  if [[ "$REPO_PATH" =~ [[:space:]] ]]; then
    log "WARNING: Repository/path '$REPO_PATH' contains spaces. Skipping."
    continue
  fi

  log "Processing path: $REPO_PATH | Retention: $RETENTION_DAYS days | Keep Last: $KEEP_LAST_N"

  if ! path_exists "$REPO_PATH"; then
    log "WARNING: Repository/path '$REPO_PATH' does not exist. Skipping."
    continue
  fi

  if [[ ! "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    log "WARNING: Invalid retention value '$RETENTION_DAYS' for path '$REPO_PATH'. Skipping."
    continue
  fi

  if [[ ! "$KEEP_LAST_N" =~ ^[0-9]+$ ]]; then
    log "WARNING: Invalid keep_last_n value '$KEEP_LAST_N' for path '$REPO_PATH'. Skipping."
    continue
  fi

  #######################################
  # Get immediate children (files and folders)
  #######################################
  
  # Get folder info to list immediate children
  FOLDER_INFO=$(jf rt curl -s "api/storage/$REPO_PATH" 2>&1)
  
  if ! echo "$FOLDER_INFO" | jq empty 2>/dev/null; then
    log "WARNING: Invalid response for path '$REPO_PATH'. Skipping."
    continue
  fi
  
  # Extract files in current directory
  mapfile -t FILES < <(echo "$FOLDER_INFO" | jq -r '.children[]? | select(.folder == false) | .uri' | sed 's:^/::')
  
  # Extract subdirectories in current directory
  mapfile -t FOLDERS < <(echo "$FOLDER_INFO" | jq -r '.children[]? | select(.folder == true) | .uri' | sed 's:^/::')
  
  # Log what was detected
  FILE_LIST_COUNT=${#FILES[@]}
  FOLDER_LIST_COUNT=${#FOLDERS[@]}
  
  # Count non-empty entries
  ACTUAL_FILES=0
  for f in "${FILES[@]}"; do
    [[ -n "$f" ]] && ACTUAL_FILES=$((ACTUAL_FILES + 1))
  done
  
  ACTUAL_FOLDERS=0
  for f in "${FOLDERS[@]}"; do
    [[ -n "$f" ]] && ACTUAL_FOLDERS=$((ACTUAL_FOLDERS + 1))
  done
  
  log "Detected immediate children: $ACTUAL_FILES file(s), $ACTUAL_FOLDERS folder(s)"
  # Combine into single array with full paths and types
  declare -a ALL_ITEMS=()
  declare -a ITEM_TYPES=()
  declare -a ITEM_DATES=()
  
  # Process files
  for file in "${FILES[@]}"; do
    [[ -z "$file" ]] && continue
    
    full_path="${REPO_PATH}/${file}"
    
    # Extract repo name and path components
    repo_name=$(echo "$REPO_PATH" | cut -d'/' -f1)
    
    # Get the path part (everything after repo name)
    if [[ "$REPO_PATH" == *"/"* ]]; then
      path_part=$(echo "$REPO_PATH" | cut -d'/' -f2-)
    else
      path_part="."
    fi
    
    # Get file info directly from storage API (simpler and more reliable)
    file_info=$(jf rt curl -s "api/storage/$full_path" 2>&1)
    
    # Extract modified date from the response
    modified_date=$(echo "$file_info" | jq -r '.lastModified // empty')
    
    if [[ -n "$modified_date" ]]; then
      log "Found file: $full_path (modified: $modified_date)"
      ALL_ITEMS+=("$full_path")
      ITEM_TYPES+=("file")
      ITEM_DATES+=("$modified_date")
    else
      log "WARNING: Could not get modification date for file: $full_path"
    fi
  done
  
  # Process folders
  for folder in "${FOLDERS[@]}"; do
    [[ -z "$folder" ]] && continue
    
    full_path="${REPO_PATH}/${folder}"
    
    # Get the most recent modified date from all nested files
    log "Checking folder modification date: $full_path"
    
    # Extract repo and path components
    repo_name=$(echo "$full_path" | cut -d'/' -f1)
    folder_path=$(echo "$full_path" | cut -d'/' -f2-)
    
    # Build AQL to find most recent file in this folder
    folder_aql=$(cat <<EOF
items.find({
  "repo": "$repo_name",
  "\$or": [
    {
      "path": "$folder_path"
    },
    {
      "path": { "\$match": "${folder_path}/*" }
    }
  ],
  "type": "file"
}).include("modified").sort({ "\$desc": ["modified"] }).limit(1)
EOF
)
    
    folder_result=$(jf rt curl -s -XPOST api/search/aql \
      -H "Content-Type: text/plain" \
      -d "$folder_aql" 2>&1)
    
    modified_date=$(echo "$folder_result" | jq -r '.results[0].modified // empty')
    
    if [[ -n "$modified_date" ]]; then
      log "Found folder: $full_path (newest file modified: $modified_date)"
      ALL_ITEMS+=("$full_path")
      ITEM_TYPES+=("folder")
      ITEM_DATES+=("$modified_date")
    else
      log "WARNING: Could not determine modification date for folder '$full_path'. Skipping."
    fi
  done
  
  TOTAL_ITEMS=${#ALL_ITEMS[@]}
  
  if [[ "$TOTAL_ITEMS" -eq 0 ]]; then
    log "No items found in path '$REPO_PATH'"
    continue
  fi
  
  # Count files and folders for better reporting
  FILE_COUNT=0
  FOLDER_COUNT=0
  for item_type in "${ITEM_TYPES[@]}"; do
    if [[ "$item_type" == "file" ]]; then
      FILE_COUNT=$((FILE_COUNT + 1))
    else
      FOLDER_COUNT=$((FOLDER_COUNT + 1))
    fi
  done
  
  log "Found $TOTAL_ITEMS items in path '$REPO_PATH' (Files: $FILE_COUNT, Folders: $FOLDER_COUNT)"
  
  # Create array of indices with dates for sorting
  declare -a SORTED_INDICES=()
  
  # Create index array
  for i in $(seq 0 $((TOTAL_ITEMS - 1))); do
    SORTED_INDICES+=("$i")
  done
  
  # Bubble sort indices by date (descending - newest first)
  for ((i = 0; i < TOTAL_ITEMS - 1; i++)); do
    for ((j = 0; j < TOTAL_ITEMS - i - 1; j++)); do
      idx1=${SORTED_INDICES[$j]}
      idx2=${SORTED_INDICES[$((j + 1))]}
      
      date1="${ITEM_DATES[$idx1]}"
      date2="${ITEM_DATES[$idx2]}"
      
      # Compare dates (newer dates are "greater")
      if [[ "$date1" < "$date2" ]]; then
        # Swap
        temp=${SORTED_INDICES[$j]}
        SORTED_INDICES[$j]=${SORTED_INDICES[$((j + 1))]}
        SORTED_INDICES[$((j + 1))]=$temp
      fi
    done
  done
  
  DELETED_COUNT=0
  PROTECTED_COUNT=0
  SKIPPED_COUNT=0
  
  # Process each item in sorted order (newest first)
  for i in $(seq 0 $((TOTAL_ITEMS - 1))); do
    idx=${SORTED_INDICES[$i]}
    item="${ALL_ITEMS[$idx]}"
    item_type="${ITEM_TYPES[$idx]}"
    item_date="${ITEM_DATES[$idx]}"
    
    # Check if item is older than retention period
    if ! is_older_than_days "$item_date" "$RETENTION_DAYS"; then
      log "Skipping recent $item_type [$((i+1))/$TOTAL_ITEMS]: $item (modified: $item_date)"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    
    # Protect the first KEEP_LAST_N old items (newest of the old ones)
    if [[ $PROTECTED_COUNT -lt $KEEP_LAST_N ]]; then
      log "Protecting old $item_type [$((i+1))/$TOTAL_ITEMS]: $item (modified: $item_date)"
      PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
      continue
    fi
    
    # Delete the rest
    if [[ "$DRY_RUN" == true ]]; then
      log "[DRY-RUN] Would delete $item_type [$((i+1))/$TOTAL_ITEMS]: $item (modified: $item_date)"
      DELETED_COUNT=$((DELETED_COUNT + 1))
    else
      log "Deleting $item_type [$((i+1))/$TOTAL_ITEMS]: $item (modified: $item_date)"
      
      if [[ "$item_type" == "folder" ]]; then
        # For folders, use recursive delete
        if jf rt del "$item/" --quiet >/dev/null 2>&1; then
          DELETED_COUNT=$((DELETED_COUNT + 1))
          log "Successfully deleted folder: $item"
        else
          EXIT_CODE=$?
          log "WARNING: Failed to delete folder $item (exit code: $EXIT_CODE)"
        fi
      else
        # For files
        if jf rt del "$item" --quiet >/dev/null 2>&1; then
          DELETED_COUNT=$((DELETED_COUNT + 1))
          log "Successfully deleted file: $item"
        else
          EXIT_CODE=$?
          log "WARNING: Failed to delete file $item (exit code: $EXIT_CODE)"
        fi
      fi
    fi
  done
  
  log "Path '$REPO_PATH' summary: Skipped (too recent)=$SKIPPED_COUNT, Protected (old but kept)=$PROTECTED_COUNT, Deleted/Would delete=$DELETED_COUNT"
  
  # Clear arrays for next iteration
  unset ALL_ITEMS
  unset ITEM_TYPES
  unset ITEM_DATES
  unset SORTED_INDICES


done < "$CONFIG_FILE"

log "===== Artifactory Cleanup Job Completed ====="