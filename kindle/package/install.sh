#!/bin/sh
set -e

DOCS="/mnt/us/documents"
LAUNCHER="$DOCS/ai_quota_dashboard.sh"
STOPPER="$DOCS/ai_quota_stop.sh"

rm -f "$LAUNCHER" "$STOPPER"
mv payload/ai_quota_dashboard.sh "$LAUNCHER"
mv payload/ai_quota_stop.sh "$STOPPER"
chmod 755 "$LAUNCHER" "$STOPPER"
lipc-set-prop com.lab126.scanner doFullScan 1 >/dev/null 2>&1 || true
sync
echo "Kindle AI Quota Dashboard installed."
