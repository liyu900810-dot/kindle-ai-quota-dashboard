#!/bin/sh

DOCS="/mnt/us/documents"
lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true
killall kindle_browser >/dev/null 2>&1 || true
if [ -d /etc/upstart ]; then
  status lab126_gui 2>/dev/null | grep -q running || start lab126_gui >/dev/null 2>&1 || true
else
  /etc/init.d/framework start >/dev/null 2>&1 || true
fi
rm -f "$DOCS/ai_quota_dashboard.sh" "$DOCS/ai_quota_stop.sh"
lipc-set-prop com.lab126.scanner doFullScan 1 >/dev/null 2>&1 || true
sync
echo "Kindle AI Quota Dashboard uninstalled."
