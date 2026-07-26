#!/bin/sh

lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1 || true
battery="$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)"
exec /bin/bash payload/dashboard_browser.sh "__DASHBOARD_URL__?battery=${battery}"
