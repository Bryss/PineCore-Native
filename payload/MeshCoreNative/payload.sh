#!/bin/bash

# Title: MeshCore Native
# Description: Vibe-coded PoC - native MeshCore companion (meshcored) for the Glytch Mesh Mod. Start/Stop, contact QR; Enable at Boot defaults OFF
# Author: Bryss
# Version: 1

# WARNING: vibe-coded proof of concept. See README.md before using.
#
# Runs meshcored, the real MeshCore companion firmware built for Linux
# (l5yth/meshcore-linux) with a CH341 radio HAL, cross-compiled as one static
# binary for the Pager. The MeshCore app connects over TCP to 172.16.52.1:5000.
# Radio region, name and TX power are set from the app, like any companion.
# No internet needed: the binary ships next to this file.

set -u
if ! command -v LOG >/dev/null 2>&1; then LOG() { printf '%s\n' "$*"; }; fi

PAYLOAD_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN='/usr/bin/meshcored'
INI='/etc/meshcored/meshcored.ini'
STATE='/root/.meshcored'
SERVICE='/etc/init.d/meshcored'
UCI_FILE='/etc/config/meshcored'
LOCK_DIR='/tmp/meshcored-payload.lock'
PORT=5000
PAGER_IP='172.16.52.1'

ACTION='menu'
INTERACTIVE=0
lock_owned=0

cleanup() {
  if [ "$lock_owned" -eq 1 ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  LOG "FAIL: $*"
  if [ "$INTERACTIVE" -eq 1 ] && command -v ERROR_DIALOG >/dev/null 2>&1; then ERROR_DIALOG "$*" >/dev/null 2>&1 || true; fi
  exit 1
}

lock_action() {
  (umask 077; mkdir "$LOCK_DIR") 2>/dev/null || fail "Another MeshCore action is running (stale? remove $LOCK_DIR)"
  lock_owned=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid" || fail 'Cannot record the action lock'
}

confirmed() {
  [ -n "$1" ] && [ "$1" != 0 ] && { [ "$1" = 1 ] || [ "$1" = "${DUCKYSCRIPT_USER_CONFIRMED:-CONFIRMED}" ]; }
}

installed() { [ -x "$BIN" ] && [ -x "$SERVICE" ]; }
running_pid() { pidof meshcored 2>/dev/null | awk '{print $1}'; }
port_listening() { netstat -lnt 2>/dev/null | awk -v p=":$PORT" '$1 ~ /^tcp/ && $4 ~ p"$" && $6 == "LISTEN" {ok=1} END {exit !ok}'; }
boot_enabled() { [ "$(uci -q get meshcored.settings.boot 2>/dev/null)" = 1 ] && [ -L /etc/rc.d/S99meshcored ]; }

service_registered() {
  local def
  def="$(ubus -S call service list '{"name":"meshcored"}' 2>/dev/null)" || return 1
  [ "$(printf '%s' "$def" | tr -d ' \t\r\n')" != '{}' ]
}

mesh_mod_count() {
  local p n=0
  for p in /sys/bus/usb/devices/*/idVendor; do
    [ -f "$p" ] || continue
    [ "$(cat "$p")" = 1a86 ] && [ "$(cat "${p%/idVendor}/idProduct" 2>/dev/null)" = 5512 ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

public_key() {
  # identity/_main.id = 32-byte public key followed by the private key.
  [ -f "$STATE/identity/_main.id" ] || return 1
  hexdump -v -n 32 -e '32/1 "%02x"' "$STATE/identity/_main.id"
}

write_init_script() {
  local tmp
  tmp="$(mktemp "$SERVICE.XXXXXX")" || fail 'Cannot stage the init script'
  cat > "$tmp" <<'MESHCORED_INIT'
#!/bin/sh /etc/rc.common
# MeshCore companion (meshcored), installed by the MeshCore Native payload.
# Boot start only when "Enable at Boot" is ON (uci meshcored.settings.boot=1).

START=99
STOP=10
USE_PROCD=1

boot() {
	[ "$(uci -q get meshcored.settings.boot)" = 1 ] || return 0
	start "$@"
}

start_service() {
	mkdir -p /root/.meshcored
	procd_open_instance
	procd_set_param command /usr/bin/meshcored --fsdir /root/.meshcored
	procd_set_param respawn 3600 10 5
	procd_set_param term_timeout 10
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
MESHCORED_INIT
  chmod 755 "$tmp" && mv "$tmp" "$SERVICE" || { rm -f "$tmp"; fail 'Cannot install the init script'; }
}

do_install() {
  local was_running=0 avail
  [ -f "$PAYLOAD_DIR/meshcored" ] && [ -f "$PAYLOAD_DIR/SHA256SUMS" ] || fail "meshcored and SHA256SUMS must sit next to payload.sh"
  (cd "$PAYLOAD_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || fail 'Bundled files fail their checksum; re-copy the payload folder'
  [ "$(readlink -f /root 2>/dev/null)" = /mmc/root ] && [ -w /mmc/root ] || fail 'Persistent eMMC home (/mmc/root) is unavailable'
  if [ -n "$(running_pid)" ] || service_registered; then was_running=1; stop_server quiet; fi
  avail="$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
  [ -n "$avail" ] && [ "$avail" -ge 2048 ] || fail "Need 2 MB free on /overlay (have ${avail:-?} KB)"

  cp "$PAYLOAD_DIR/meshcored" "$BIN.tmp" && chmod 755 "$BIN.tmp" && mv "$BIN.tmp" "$BIN" || fail "Cannot install $BIN"
  "$BIN" --version >/dev/null 2>&1 || fail 'meshcored does not run on this Pager'
  mkdir -p /etc/meshcored "$STATE" && chmod 700 "$STATE"
  if [ ! -f "$INI" ]; then
    cp "$PAYLOAD_DIR/meshcored.ini" "$INI" || fail "Cannot install $INI"
  else
    LOG "Keeping existing $INI"
  fi
  write_init_script
  [ -f "$UCI_FILE" ] || printf "config settings 'settings'\n\toption boot '0'\n" > "$UCI_FILE"
  LOG "meshcored installed. State: $STATE"
  [ "$was_running" -eq 0 ] || start_server
}

start_server() {
  local n attempt pid
  installed || fail 'Not installed; choose Install / Update first'
  if pid="$(running_pid)" && [ -n "$pid" ]; then LOG "meshcored already running (PID $pid) on $PAGER_IP:$PORT"; return 0; fi
  n="$(mesh_mod_count)"
  [ "$n" -gt 0 ] || fail 'Glytch Mesh Mod (USB 1a86:5512) not detected; attach it (and its antenna!) and retry'
  [ "$n" -eq 1 ] || fail 'More than one CH341 radio is attached; leave only the Mesh Mod connected'
  [ -z "$(pidof meshtasticd 2>/dev/null || true)" ] || fail 'Meshtastic is using the Mesh Mod; stop it in the Meshtastic payload first'
  ! grep -qs 'pinecore.py' /proc/[0-9]*/cmdline || fail 'PineCore (Python) is using the Mesh Mod; stop it first'

  "$SERVICE" start || fail 'Service start failed'
  for ((attempt = 0; attempt < 20; attempt++)); do
    if [ -n "$(running_pid)" ] && port_listening; then
      LOG "meshcored running (PID $(running_pid)). MeshCore app: TCP $PAGER_IP port $PORT"
      return 0
    fi
    sleep 1
  done
  logread 2>/dev/null | grep 'meshcored\[' | tail -n 8 | while IFS= read -r line; do LOG "$line"; done
  "$SERVICE" stop >/dev/null 2>&1 || true
  fail 'meshcored did not come up; see the log lines above (logread | grep meshcored)'
}

stop_server() {
  local attempt
  [ ! -x "$SERVICE" ] || "$SERVICE" stop >/dev/null 2>&1 || true
  for ((attempt = 0; attempt < 15; attempt++)); do
    if [ -z "$(running_pid)" ] && ! service_registered; then
      [ "${1:-}" = quiet ] || LOG 'meshcored stopped'
      return 0
    fi
    sleep 1
  done
  fail 'meshcored did not stop; check: ps | grep meshcored'
}

show_qr() {
  local key url
  key="$(public_key)" || fail 'No identity yet; start the server once first'
  url="meshcore://contact/add?name=Pager&public_key=$key&type=1"
  LOG "$url"
  PROMPT_QR "$url" 'MeshCore: scan to add this Pager' >/dev/null 2>&1 || true
}

boot_on() {
  installed || fail 'Install / Update first'
  uci set meshcored.settings=settings && uci set meshcored.settings.boot=1 && uci commit meshcored || fail 'Cannot save the boot choice'
  "$SERVICE" enable || fail 'Boot enable failed'
  LOG 'Enable at Boot: ON. The current session is unchanged.'
}

boot_off() {
  if [ -f "$UCI_FILE" ]; then uci set meshcored.settings.boot=0 && uci commit meshcored; fi
  [ ! -x "$SERVICE" ] || "$SERVICE" disable || true
  rm -f /etc/rc.d/S99meshcored /etc/rc.d/K10meshcored
  LOG 'Enable at Boot: OFF. Manual Start still works.'
}

STATUS_JSON='/tmp/meshcored-status.json'
BATTERY='/sys/class/power_supply/bq27546-0'

sj() { jsonfilter -i "$STATUS_JSON" -e "@.$1" 2>/dev/null; }

# Average CPU of a PID over one second, from /proc/<pid>/stat utime+stime.
cpu_percent() {
  local a b
  a="$(awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null)" || return 1
  sleep 1
  b="$(awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null)" || return 1
  echo $((b - a))
}

show_status() {
  local pid lines key up age recv cpu rss now
  pid="$(running_pid)"
  now="$(date +%s)"
  if [ -n "$pid" ] && [ -f "$STATUS_JSON" ]; then
    up="$(sj uptime)"
    age=$((now - $(sj updated || echo 0)))
    recv="$(sj recv)"
    cpu="$(cpu_percent "$pid" || echo '?')"
    rss="$(awk '/^VmRSS/ {print $2}' "/proc/$pid/status" 2>/dev/null)"
    lines="MeshCore: RUNNING  pid $pid
Name: $(sj name)
App: $( [ "$(sj app_connected)" = true ] && echo connected || echo 'not connected') ($PAGER_IP:$PORT)
Radio: $(sj freq | awk '{printf "%.3f", $1}') MHz BW$(sj bw | awk '{printf "%g", $1}') SF$(sj sf) CR$(sj cr)
TX power: $(sj tx_power) dBm
Contacts: $(sj contacts)/$(sj max_contacts)  Channels: $(sj channels)
Queued msgs: $(sj queued)
RX: $recv pkts (flood $(sj flood_rx), direct $(sj direct_rx), err $(sj recv_errors))
TX: $(sj sent) pkts (flood $(sj flood_tx), direct $(sj direct_tx)), $(sj tx_air_secs)s air
Noise floor: $(sj noise_floor) dBm"
    [ "${recv:-0}" -gt 0 ] && lines="$lines
Last RX: RSSI $(sj last_rssi) dBm, SNR $(sj last_snr | awk '{printf "%.1f", $1}') dB"
    lines="$lines
Uptime: $((up / 3600))h $((up % 3600 / 60))m  CPU ${cpu}%  RAM ${rss:-?} KB"
    [ "$age" -le 30 ] || lines="$lines
(stats ${age}s old)"
  elif [ -n "$pid" ]; then
    lines="MeshCore: RUNNING  pid $pid
(waiting for first stats)"
  else
    lines='MeshCore: STOPPED'
    installed || lines="$lines
Not installed"
  fi
  if key="$(public_key)"; then lines="$lines
Key: $(printf '%s' "$key" | cut -c1-16)..."; fi
  lines="$lines
Battery: $(cat "$BATTERY/capacity" 2>/dev/null)% $(cat "$BATTERY/status" 2>/dev/null), $(($(cat "$BATTERY/voltage_now" 2>/dev/null || echo 0) / 1000)) mV
Mesh Mod: $( [ "$(mesh_mod_count)" -gt 0 ] && echo attached || echo 'NOT attached')  Boot: $(boot_enabled && echo ON || echo OFF)"
  printf '%s\n' "$lines" | while IFS= read -r l; do LOG "$l"; done
  [ "$INTERACTIVE" -eq 0 ] || PROMPT "$lines" >/dev/null 2>&1 || true
}

do_uninstall() {
  stop_server quiet
  boot_off >/dev/null
  rm -f "$SERVICE" "$UCI_FILE" "$BIN"
  LOG "meshcored uninstalled. Identity, contacts and $INI kept"
}

menu() {
  local choice boot resp
  command -v LIST_PICKER >/dev/null 2>&1 || fail 'Pager menu unavailable; use a command-line action (--help)'
  INTERACTIVE=1
  while :; do
    boot='OFF'; boot_enabled && boot='ON'
    choice="$(LIST_PICKER 'MeshCore Native' 'Start server' 'Stop server' 'Show contact QR' 'Status' \
      'Install / Update' "Enable at Boot: $boot" 'Uninstall' 'Exit' 'Start server')" || exit 0
    case "$choice" in
      'Start server') ACTION=start ;;
      'Stop server') ACTION=stop ;;
      'Show contact QR') ACTION=qr ;;
      'Status') ACTION=status ;;
      'Install / Update') ACTION=install ;;
      "Enable at Boot: $boot")
        choice="$(LIST_PICKER "Enable at Boot: $boot" 'ON - start at boot' 'OFF - manual start only' 'Back' 'Back')" || exit 0
        case "$choice" in
          'ON - start at boot') ACTION=boot-on ;;
          'OFF - manual start only') ACTION=boot-off ;;
          *) continue ;;
        esac ;;
      'Uninstall')
        resp="$(CONFIRMATION_DIALOG 'Uninstall MeshCore Native? Identity and contacts stay.')" || continue
        confirmed "$resp" || continue
        ACTION=uninstall ;;
      'Exit'|'') exit 0 ;;
      *) continue ;;
    esac
    return 0
  done
}

usage() {
  cat <<'USAGE'
Usage: payload.sh [--install|--start|--stop|--status|--qr|--boot-on|--boot-off|--uninstall]
USAGE
}

[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = hak5,wifi-pineapple-pager ] || fail 'This payload targets the WiFi Pineapple Pager'

case "${1-}" in
  '') ;;
  --install|--update) ACTION=install ;;
  --start) ACTION=start ;;
  --stop) ACTION=stop ;;
  --status) ACTION=status ;;
  --qr) ACTION=qr ;;
  --boot-on) ACTION=boot-on ;;
  --boot-off) ACTION=boot-off ;;
  --uninstall) ACTION=uninstall ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 1 ;;
esac

[ "$ACTION" != menu ] || menu
[ "$ACTION" = status ] || [ "$ACTION" = qr ] || lock_action
case "$ACTION" in
  install) do_install ;;
  start) start_server ;;
  stop) stop_server ;;
  status) show_status ;;
  qr) show_qr ;;
  boot-on) boot_on ;;
  boot-off) boot_off ;;
  uninstall) do_uninstall ;;
esac
exit 0
