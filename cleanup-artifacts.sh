#!/bin/bash
set -euo pipefail

#######################################
# CONFIGURATION
#######################################
RETENTION_DAYS=14
KEEP_LAST_N=3
REPOS=("generic-local" "libs-snapshot-local" "docker-local")
LOG_FILE="/var/log/artifactory-cleanup.log"
DRY_RUN=true   # set to false to actually delete

#######################################
# FUNCTIONS
#######################################
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

check_jfrog() {
  if ! jfrog rt ping &>/dev/null; then
    log "ERROR: JFrog CLI not configured or Artifactory unreachable"
    exit 1
  fi
}

#######################################
# START
#######################################
log "===== Artifactory Cleanup Job Started ====="
check_jfrog

for REPO in "${REPOS[@]}"; do
  log "Processing repository: $REPO"

  # AQL query: artifacts older than retention days & not retained
  AQL_QUERY=$(cat <<EOF
items.find({
  "repo": "$REPO",
  "type": "file",
  "modified": { "\$before": "${RETENTION_DAYS}d" },
  "@retain": { "\$ne": "true" }
}).sort({ "\$desc": ["modified"] })
EOF
)

  RESULTS=$(jfrog rt curl -XPOST api/search/aql -H "Content-Type: text/plain" -d "$AQL_QUERY")

  FILES=$(echo "$RESULTS" | jq -r '.results[].repo + "/" + .results[].path + "/" + .results[].name')

  COUNT=0
  for FILE in $FILES; do
    ((COUNT++))
    if [[ $COUNT -le $KEEP_LAST_N ]]; then
      log "Skipping recent artifact (protected): $FILE"
      continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
      log "[DRY-RUN] Would delete: $FILE"
    else
      log "Deleting: $FILE"
      jfrog rt del "$FILE" --quiet
    fi
  done
done

log "===== Artifactory Cleanup Job Completed ====="

