#!/bin/bash
set -euo pipefail

# Keep the most recent 10 pcp_* debug artifacts in the log dir and delete the rest.
LOG_DIR=${LOG_DIR:-/var/log/pgpool}
cd "$LOG_DIR" || exit 0

# List files matching pcp_* sorted by modification time (newest first), remove older than the top 10
ls -1t pcp_* 2>/dev/null | tail -n +11 | xargs -r rm -f || true

echo "Cleanup done; retained up to 10 pcp_* files in $LOG_DIR"
