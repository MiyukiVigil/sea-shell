#!/usr/bin/env bash
# sea-sysmon — one-shot system stats sampler for the sea-shell bar.
# Emits a single pipe-delimited line; the shell polls this every few seconds.
# Fields: cpuUsage|cpuTemp|memUsed|memTotal|memPct|gpuName|gpuUtil|gpuTemp|gpuPower|gpuMemUsed|gpuMemTotal
# Missing values are 0 (or "" for gpuName when no discrete GPU is present).

# ---- CPU usage: two /proc/stat samples, aggregate jiffy delta ----
s1=$(head -1 /proc/stat)
sleep 0.2
s2=$(head -1 /proc/stat)
cpu=$(awk -v l1="$s1" -v l2="$s2" 'BEGIN{
  n=split(l1,a," "); split(l2,b," ");
  i1=a[5]+a[6]; i2=b[5]+b[6];               # idle + iowait
  t1=0; t2=0; for(k=2;k<=n;k++){t1+=a[k]; t2+=b[k]}
  d=t2-t1; di=i2-i1;
  if(d<=0) print 0; else printf "%.0f",(1-di/d)*100
}')

# ---- CPU package temperature (Intel coretemp / AMD k10temp) ----
ct=""
for h in /sys/class/hwmon/hwmon*; do
  [ "$(cat "$h/name" 2>/dev/null)" = coretemp ] && { ct=$(cat "$h/temp1_input" 2>/dev/null); break; }
done
if [ -z "$ct" ]; then
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = k10temp ] && { ct=$(cat "$h/temp1_input" 2>/dev/null); break; }
  done
fi
ctemp=0
[ -n "$ct" ] && ctemp=$((ct/1000))

# ---- RAM: used|total (GiB) | percent ----
mem=$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{
  printf "%.1f|%.1f|%.0f",(t-a)/1048576,t/1048576,(t-a)/t*100
}' /proc/meminfo)

# ---- GPU (NVIDIA via nvidia-smi) — name|util|temp|power|vramUsed|vramTotal ----
gpu="|0|0|0|0|0"
if command -v nvidia-smi >/dev/null 2>&1; then
  g=$(nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,power.draw,memory.used,memory.total \
        --format=csv,noheader,nounits 2>/dev/null | head -1)
  if [ -n "$g" ]; then
    gpu=$(echo "$g" | awk -F', *' '{
      name=$1; sub(/^NVIDIA /,"",name); sub(/ Laptop GPU$/,"",name); sub(/GeForce /,"",name);
      printf "%s|%.0f|%.0f|%.1f|%.1f|%.1f",name,$2,$3,$4,$5/1024,$6/1024
    }')
  fi
fi

printf "%s|%s|%s|%s\n" "$cpu" "$ctemp" "$mem" "$gpu"
