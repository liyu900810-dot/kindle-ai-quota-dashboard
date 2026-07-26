#!/bin/bash
# Name: AI 额度中控台
# Author: Community contributors
# DontUseFBInk
# Last-opened: 0

timestamp=$(date +%s)
sed -i "s/^# Last-opened:.*/# Last-opened: $timestamp/" "$0"
exec /var/local/kmc/bin/kpm launch kindle-ai-quota-dashboard
