#!/bin/zsh
# Measures an already running WCleaner: CPU time used, resident memory and physical footprint while idle.
# Usage: scripts/measure-idle.sh [seconds=120]
# Start WCleaner first (for example the Release build) and let it settle for ~15 seconds.
set -euo pipefail

DURATION=${1:-120}
PID=$(/usr/bin/pgrep -x WCleaner | head -1 || true)
[[ -n "$PID" ]] || { print -u2 "WCleaner is not running."; exit 1; }

cpu_seconds() {
  # ps prints cumulative CPU time as [[dd-]hh:]mm:ss.cc
  /bin/ps -o time= -p "$PID" | /usr/bin/awk -F'[:-]' '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}

print "Machine: $(/usr/sbin/sysctl -n machdep.cpu.brand_string), $(( $(/usr/sbin/sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
print "PID $PID, sampling every 10 s for $DURATION s"
start=$(cpu_seconds)
for (( t = 10; t <= DURATION; t += 10 )); do
  sleep 10
  print "t=${t}s rss_kb=$(/bin/ps -o rss= -p "$PID" | tr -d ' ') cpu_time_s=$(cpu_seconds)"
done
end=$(cpu_seconds)
print "CPU time used during the window: $(( end - start )) s (average $(( (end - start) * 100.0 / DURATION ))% of one core)"
/usr/bin/footprint -p "$PID" 2>/dev/null | /usr/bin/grep -E "phys_footprint" || true
/usr/bin/top -l 2 -s 10 -pid "$PID" -stats pid,cpu,idlew,mem | tail -1
