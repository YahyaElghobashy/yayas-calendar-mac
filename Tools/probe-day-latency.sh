#!/bin/zsh
# Live latency probe for Month day taps on the INSTALLED app (needs a placed Month widget):
# fires `open -g yayacal://day?w=month&d=…` N times, alternating days, and measures
# link → app receipt and app receipt → next `widget render kind=month` in the traces.
#   Tools/probe-day-latency.sh [N=10] [kind=month]
set -uo pipefail
N=${1:-10}; KIND=${2:-month}
A="$HOME/Library/Application Support/YayasCalendar/logs/app.log"
W="$HOME/Library/Application Support/YayasCalendar/widget/trace.log"
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
days=( $(python3 -c 'import datetime as d;t=d.date.today();print(" ".join(str(t+d.timedelta(days=i)) for i in (1,2,3,4,5)))') )
lat=(); rec=()
for i in $(seq 1 $N); do
  day=${days[$(( (i % 5) + 1 ))]}
  t0=$(ms); open -g "yayacal://day?w=$KIND&d=$day"
  recv=""; for _ in {1..100}; do recv=$(grep "recv day w=$KIND d=$day" "$A" | tail -1 | sed -n 's/.*at=\([0-9]*\).*/\1/p'); [[ -n "$recv" && "$recv" -ge "$t0" ]] && break; recv=""; sleep 0.05; done
  render=""; for _ in {1..200}; do render=$(awk -v t="${recv:-$t0}" -v k="kind=$KIND" '$0 ~ /widget render/ && index($0,k) && $2+0 >= t {print $2; exit}' "$W"); [[ -n "$render" ]] && break; sleep 0.05; done
  if [[ -n "$recv" && -n "$render" ]]; then echo "tap $i d=$day: link→app $((recv-t0)) ms, app→render $((render-recv)) ms"; lat+=($((render-t0))); else echo "tap $i d=$day: timeout (recv=${recv:-none})"; lat+=(99999); fi
  sleep 1.5
done
print -l $lat | sort -n | awk '{a[NR]=$1} END {printf "total tap→render p50 %d ms, p90 %d ms, max %d ms (n=%d)\n", a[int((NR+1)/2)], a[int(NR*0.9+0.5)], a[NR], NR}'
