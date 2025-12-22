# JFrog Artifactory Cleanup Script

A robust Bash script for automated cleanup of old artifacts in JFrog Artifactory repositories with configurable retention policies and protection rules.

## Features

- 🗑️ **Automated Cleanup**: Remove old artifacts based on configurable retention periods
- 🛡️ **Protection Rules**: Keep the N most recent artifacts even if they exceed retention period
- 📁 **Folder Support**: Handles both individual files and entire folder structures
- 🔍 **Smart Detection**: Uses AQL queries to determine folder modification dates based on newest file
- 🔒 **Safe by Default**: Dry-run mode enabled by default to preview deletions
- 📊 **Detailed Logging**: Comprehensive logging with timestamps for audit trails
- ⚡ **Flexible Configuration**: Simple CSV-based config file for managing multiple paths
- ✅ **Validation**: Built-in checks for invalid paths, malformed config, and prerequisites

## Prerequisites

- **JFrog CLI** (`jf`) - [Installation Guide](https://jfrog.com/getcli/)
- **jq** - JSON processor (`sudo apt-get install jq` or `brew install jq`)
- **Artifactory Access** - Configured JFrog CLI with valid credentials
- **Bash 4.0+** - For array support

## Installation

1. Clone this repository or download the script:
```bash
git clone <your-repo-url>
cd artifactory-cleanup
```

2. Make the script executable:
```bash
chmod +x cleanup.sh
```

3. Create the log directory:
```bash
mkdir -p ~/log
```

4. Verify prerequisites:
```bash
jf --version
jq --version
jf rt ping
```

## Configuration

Create a `cleanup.conf` file in the same directory as the script with the following format:

```
# Format: REPO_PATH,RETENTION_DAYS,KEEP_LAST_N
# Lines starting with # are comments

# Examples:
maven-local/com/example/app,90,3
docker-local/images/backend,30,5
generic-local/builds/dev,7,2
```

### Configuration Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `REPO_PATH` | Repository and path to clean (no spaces) | `maven-local/releases` |
| `RETENTION_DAYS` | Days to keep artifacts | `90` |
| `KEEP_LAST_N` | Number of old artifacts to protect | `3` |

### Configuration Rules

- Each line represents one cleanup rule
- Lines starting with `#` are comments
- Empty lines are ignored
- Format: `REPO_PATH,RETENTION_DAYS,KEEP_LAST_N`
- No spaces allowed in repository paths
- Values must be positive integers

## Usage

### Dry Run (Safe Mode - Default)

Preview what would be deleted without actually removing anything:

```bash
./cleanup.sh
```

### Live Deletion

**⚠️ Warning: This will permanently delete artifacts!**

Edit the script and change:
```bash
DRY_RUN=false   # change to false to enable deletion
```

Then run:
```bash
./cleanup.sh
```

### Viewing Logs

```bash
tail -f ~/log/artifactory-cleanup.log
```

## How It Works

### Cleanup Logic

1. **Read Configuration**: Parses `cleanup.conf` for cleanup rules
2. **Validate Prerequisites**: Checks for required tools and Artifactory connectivity
3. **Process Each Path**: For each configured repository path:
   - Lists all immediate children (files and folders)
   - Determines modification dates:
     - **Files**: Uses last modified timestamp
     - **Folders**: Finds newest file within the folder tree
   - Sorts items by modification date (newest first)
   - Applies cleanup rules:
     - **Skip**: Items newer than retention period
     - **Protect**: First N items that exceed retention (newest of old items)
     - **Delete**: Remaining items that exceed retention

### Example Scenario

Configuration: `maven-local/releases,30,2`

Items found (sorted by date):
```
1. release-1.5.0  (5 days old)   → SKIP (too recent)
2. release-1.4.0  (10 days old)  → SKIP (too recent)
3. release-1.3.0  (35 days old)  → PROTECT (1st old item, keep_last_n=2)
4. release-1.2.0  (45 days old)  → PROTECT (2nd old item, keep_last_n=2)
5. release-1.1.0  (60 days old)  → DELETE (exceeds retention & protection limit)
6. release-1.0.0  (90 days old)  → DELETE (exceeds retention & protection limit)
```

Result: Keeps the 2 most recent releases (1.5.0, 1.4.0) plus 2 protected old releases (1.3.0, 1.2.0), deletes ancient releases (1.1.0, 1.0.0).

## Script Components

### Key Functions

#### `check_prereqs()`
Verifies that JFrog CLI, jq, and Artifactory connection are available.

#### `path_exists(path)`
Validates that a repository or folder path exists in Artifactory.

#### `get_folder_modified_date(path)`
Uses AQL to find the most recently modified file in a folder tree.

#### `is_older_than_days(modified_date, retention_days)`
Compares a modification date against the retention period.

### Configuration Variables

```bash
CONFIG_FILE="./cleanup.conf"           # Path to configuration file
LOG_FILE="$HOME/log/artifactory-cleanup.log"  # Log file location
DRY_RUN=true                           # Set to false for actual deletion
```

## Logging

All operations are logged to `~/log/artifactory-cleanup.log` with timestamps:

```
2024-12-22 10:30:45 | ===== Artifactory Cleanup Job Started =====
2024-12-22 10:30:46 | Processing path: maven-local/releases | Retention: 90 days | Keep Last: 3
2024-12-22 10:30:47 | Found 15 items in path 'maven-local/releases' (Files: 10, Folders: 5)
2024-12-22 10:30:48 | Skipping recent file [1/15]: maven-local/releases/v1.5.0 (modified: 2024-12-20T10:30:00.000Z)
2024-12-22 10:30:49 | [DRY-RUN] Would delete folder [8/15]: maven-local/releases/v1.0.0 (modified: 2024-09-15T14:20:00.000Z)
2024-12-22 10:31:00 | Path 'maven-local/releases' summary: Skipped (too recent)=5, Protected (old but kept)=3, Deleted/Would delete=7
2024-12-22 10:31:01 | ===== Artifactory Cleanup Job Completed =====
```

## Scheduling with Cron

Run the cleanup automatically using cron:

```bash
# Edit crontab
crontab -e

# Run daily at 2 AM
0 2 * * * /path/to/cleanup.sh >> ~/log/artifactory-cleanup-cron.log 2>&1

# Run weekly on Sunday at 3 AM
0 3 * * 0 /path/to/cleanup.sh >> ~/log/artifactory-cleanup-cron.log 2>&1
```

## Safety Features

- ✅ **Dry-run by default**: Preview deletions before executing
- ✅ **Path validation**: Skips non-existent paths
- ✅ **Input validation**: Checks for malformed configuration
- ✅ **Protection rules**: Always keeps N most recent old artifacts
- ✅ **Comprehensive logging**: Full audit trail of all operations
- ✅ **Error handling**: Graceful failure with informative messages

## Troubleshooting

### "jf CLI not installed"
Install JFrog CLI: https://jfrog.com/getcli/

### "Cannot connect to Artifactory"
Configure JFrog CLI:
```bash
jf config add
```

### "Repository/path does not exist"
Verify the path in Artifactory UI or using:
```bash
jf rt curl -s "api/storage/REPO_PATH"
```

### "Invalid retention value"
Ensure RETENTION_DAYS is a positive integer in `cleanup.conf`.

### "Could not determine modification date for folder"
The folder may be empty or contain only subdirectories without files.

## Best Practices

1. **Always test with dry-run first** before enabling actual deletion
2. **Start with conservative retention periods** (e.g., 90+ days)
3. **Set KEEP_LAST_N > 0** to prevent accidental deletion of all artifacts
4. **Monitor logs regularly** to ensure cleanup is working as expected
5. **Back up critical artifacts** before running cleanup
6. **Review config file** for typos or incorrect paths
7. **Test on non-production repositories** first

## Example Use Cases

### Maven Releases
Keep last 90 days, always protect 5 most recent old versions:
```
maven-local/com/example/app,90,5
```

### Docker Images
Keep last 30 days of development images, protect last 3:
```
docker-local/images/dev,30,3
```

### Build Artifacts
Aggressive cleanup: 7 days retention, keep last 2:
```
generic-local/builds/feature-branches,7,2
```

### Snapshots
Very short retention for SNAPSHOT builds:
```
maven-local/snapshots,3,1
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

[Your chosen license - e.g., MIT, Apache 2.0]

## Author

[Your name/organization]

## Support

For issues or questions:
- Open an issue on GitHub
- Check JFrog documentation: https://jfrog.com/help/
- Review logs in `~/log/artifactory-cleanup.log`

---

**⚠️ Important Reminder**: This script permanently deletes artifacts. Always test with DRY_RUN=true first and ensure you have proper backups before running in production!
