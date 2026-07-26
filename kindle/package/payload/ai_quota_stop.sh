#!/bin/bash
# Name: 退出 AI 额度中控台
# Author: Community contributors
# DontUseFBInk

refresh_screen() {
  eips -c >/dev/null 2>&1
  eips -c >/dev/null 2>&1
}

lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true
killall kindle_browser >/dev/null 2>&1 || true
if [ -d /etc/upstart ]; then
  status lab126_gui 2>/dev/null | grep -q running || start lab126_gui >/dev/null 2>&1 || true
  usleep 1250000
else
  /etc/init.d/framework start >/dev/null 2>&1 || true
fi
refresh_screen
exit 0
