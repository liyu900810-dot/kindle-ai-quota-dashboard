#!/bin/bash

URL="$1"
[ -n "$URL" ] || exit 1

refresh_screen() {
  eips -c >/dev/null 2>&1
  eips -c >/dev/null 2>&1
}

restore_gui() {
  kill $watcher_pids 2>/dev/null || true
  [ -n "$browser_pid" ] && kill -9 "$browser_pid" 2>/dev/null || true
  rm -f "$STOP_FLAG"
  lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true
  if [ -d /etc/upstart ]; then
    status lab126_gui 2>/dev/null | grep -q running || start lab126_gui >/dev/null 2>&1 || true
    usleep 1250000
  else
    /etc/init.d/framework start >/dev/null 2>&1 || true
  fi
  refresh_screen
}

trap restore_gui EXIT INT TERM
refresh_screen
if [ -d /etc/upstart ]; then
  trap '' TERM
  stop lab126_gui >/dev/null 2>&1 || true
  usleep 1250000
  trap restore_gui EXIT INT TERM
  start kb >/dev/null 2>&1 || true
else
  /etc/init.d/framework stop >/dev/null 2>&1 || true
fi

refresh_screen
export XDG_CONFIG_HOME="/mnt/us/system/browser/"
export LD_LIBRARY_PATH="/usr/bin/chromium/lib:/usr/bin/chromium/usr/lib:/usr/lib/"

nohup /usr/bin/chromium/bin/kindle_browser "$URL" --no-zygote --no-sandbox --single-process \
  --skia-resource-cache-limit-mb=64 --disable-gpu --in-process-gpu --disable-gpu-sandbox \
  --disable-gpu-compositing --force-device-scale-factor=1 --js-flags=jitless \
  --content-shell-hide-toolbar --content-shell-host-window-cord=0,215 \
  --force-gpu-mem-available-mb=32 --enable-grayscale-mode --enable-low-end-device-mode \
  --enable-low-res-tiling --disable-site-isolation-trials \
  --user-agent="Mozilla/5.0 (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+" \
  >/dev/null 2>&1 &

browser_pid=$!
unset LD_LIBRARY_PATH
STOP_FLAG="/tmp/kindle-ai-quota-stop.$$"
rm -f "$STOP_FLAG"
watcher_pids=""

for DEV in /dev/input/event*; do
  [ -r "$DEV" ] || continue
  (
    while [ ! -e "$STOP_FLAG" ]; do
      event=$(dd if="$DEV" bs=16 count=1 2>/dev/null | hexdump -v -e '16/1 "%02X"')
      [ ${#event} -ge 32 ] || continue
      type="${event:16:4}"
      code="${event:20:4}"
      value="${event:24:8}"
      if [ "$type" = "0100" ] && [ "$code" = "7400" ] && [ "$value" = "01000000" ]; then
        touch "$STOP_FLAG"
        break
      fi
    done
  ) &
  watcher_pids="$watcher_pids $!"
done

while kill -0 "$browser_pid" 2>/dev/null && [ ! -e "$STOP_FLAG" ]; do
  sleep 1
done

exit 0
