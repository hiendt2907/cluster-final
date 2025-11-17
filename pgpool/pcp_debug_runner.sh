#!/bin/bash
set -euo pipefail

# Debug helper: run a PCP client under ltrace (if present) and capture tcpdump on loopback.
# Writes artifacts to /var/log/pgpool by default. Useful for diagnosing PCP challenge/response.

LOG_DIR=${LOG_DIR:-/var/log/pgpool}
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
LTRACE_LOG="$LOG_DIR/pcp_ltrace_${TIMESTAMP}.log"
PCAP="$LOG_DIR/pcp_${TIMESTAMP}.pcap"
OUT="$LOG_DIR/pcp_output_${TIMESTAMP}.log"

# Default command (pcp_node_count) when no args provided
if [ "$#" -eq 0 ]; then
  CMD=(pcp_node_count -h localhost -p 9898 -U "${PCP_USER:-pcp_admin}" -w)
else
  CMD=("$@")
fi

# start tcpdump if available
TCPDUMP_PID=""
if command -v tcpdump >/dev/null 2>&1; then
  # capture on loopback for PCP port 9898
  tcpdump -i lo -s 0 -w "$PCAP" port 9898 >/dev/null 2>&1 &
  TCPDUMP_PID=$!
fi

# run command under ltrace if available, otherwise run normally
if command -v ltrace >/dev/null 2>&1; then
  # limit runtime to 10s to avoid hanging tests
  timeout 10s ltrace -f -o "$LTRACE_LOG" -- "${CMD[@]}" >"$OUT" 2>&1 || true
else
  timeout 10s "${CMD[@]}" >"$OUT" 2>&1 || true
fi

# stop tcpdump if it was started
if [ -n "$TCPDUMP_PID" ]; then
  kill "$TCPDUMP_PID" 2>/dev/null || true
  wait "$TCPDUMP_PID" 2>/dev/null || true
fi

echo "pcp debug artifacts written:"
[ -f "$LTRACE_LOG" ] && echo "  ltrace: $LTRACE_LOG"
[ -f "$PCAP" ] && echo "  pcap:  $PCAP"
[ -f "$OUT" ] && echo "  out:   $OUT"

exit 0
