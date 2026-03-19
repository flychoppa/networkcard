#!/usr/bin/env bash
set -e

echo "[+] Installing rps-xps setup..."

# --- 1. Основной скрипт ---
cat >/usr/local/sbin/rps-xps.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CFG="/etc/default/rps-xps"
[[ -r "$CFG" ]] && source "$CFG"

: "${RPSXPS_INTERFACES:=auto}"
: "${RPSXPS_CPU_MASK:=}"
: "${RPSXPS_CPU_LIST:=}"
: "${RPSXPS_CPU_AUTO:=1}"
: "${RPSXPS_CPU_COUNT:=0}"
: "${RPSXPS_CPU_START:=0}"
: "${RPSXPS_EXCLUDE_CPU0:=0}"
: "${RPSXPS_RPS_SOCK_FLOW_ENTRIES:=131072}"
: "${RPSXPS_RPS_FLOW_CNT:=auto}"
: "${RPSXPS_ENABLE_RFS:=1}"
: "${RPSXPS_ENABLE_RPS:=1}"
: "${RPSXPS_ENABLE_XPS:=1}"
: "${RPSXPS_ENABLE_XPS_RXQS:=1}"

log() { echo "[rps-xps] $*"; }

write_sysfs() {
  local path="$1" val="$2"
  [[ -w "$path" ]] && printf "%s\n" "$val" >"$path" 2>/dev/null || true
}

get_online_cpulist() {
  cat /sys/devices/system/cpu/online 2>/dev/null || echo "0"
}

cpulist_to_mask() {
  python3 - "$1" <<'PY'
import sys
cpus=set()
for part in sys.argv[1].replace(',', ' ').split():
    if '-' in part:
        a,b=map(int,part.split('-'))
        for i in range(a,b+1): cpus.add(i)
    else:
        cpus.add(int(part))
mask=0
for c in cpus:
    mask |= (1<<c)
print(format(mask,'x'))
PY
}

resolve_cpu_mask() {
  [[ -n "$RPSXPS_CPU_MASK" ]] && { echo "$RPSXPS_CPU_MASK"; return; }
  local list
  if [[ -n "$RPSXPS_CPU_LIST" ]]; then
    list="$RPSXPS_CPU_LIST"
  else
    list="$(get_online_cpulist)"
  fi
  cpulist_to_mask "$list"
}

apply_one_iface() {
  local dev="$1"
  [[ -d "/sys/class/net/$dev" ]] || return

  local cpu_mask
  cpu_mask="$(resolve_cpu_mask)"

  log "Applying on $dev with mask $cpu_mask"

  for q in /sys/class/net/"$dev"/queues/rx-*; do
    write_sysfs "$q/rps_cpus" "$cpu_mask"
  done

  for q in /sys/class/net/"$dev"/queues/tx-*; do
    write_sysfs "$q/xps_cpus" "$cpu_mask"
  done
}

main() {
  local dev
  dev=$(ip -o route show default | awk '{print $5}' | head -n1)
  apply_one_iface "$dev"
  log "Done"
}

main "$@"
EOF

chmod +x /usr/local/sbin/rps-xps.sh

# --- 2. Конфиг ---
cat >/etc/default/rps-xps <<'EOF'
RPSXPS_INTERFACES="auto"
RPSXPS_CPU_AUTO=1
RPSXPS_EXCLUDE_CPU0=0

RPSXPS_RPS_SOCK_FLOW_ENTRIES=131072
RPSXPS_RPS_FLOW_CNT=auto

RPSXPS_ENABLE_RFS=1
RPSXPS_ENABLE_RPS=1
RPSXPS_ENABLE_XPS=0
RPSXPS_ENABLE_XPS_RXQS=0
EOF

# --- 3. systemd сервис ---
cat >/etc/systemd/system/rps-xps.service <<'EOF'
[Unit]
Description=Apply RPS/XPS/RFS settings
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rps-xps.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# --- 4. Включение ---
systemctl daemon-reload
systemctl enable --now rps-xps.service

# --- 5. irqbalance ---
apt-get update -y
apt-get install -y irqbalance
systemctl enable --now irqbalance

# --- 6. Проверка ---
echo
echo "[+] STATUS:"
systemctl status rps-xps.service --no-pager || true

echo
echo "[+] CPU usage test:"
echo "Run: mpstat -P ALL 1 5"

echo
echo "[✓] Installation complete"
