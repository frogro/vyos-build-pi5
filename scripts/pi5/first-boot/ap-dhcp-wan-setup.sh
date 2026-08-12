#!/bin/vbash
# VyOS wireless AP, DHCP, and optional Ethernet WAN setup for Raspberry Pi 5 - Version 8.3-pi5 - dynamic PHY binding and WAN detection
# Erkennt alle WLAN-devicee, laesst einen AP-faehigen Adapter auswaehlen,
# uses the selected MAC only for detection/cache and does not bind VyOS to it,
# configures the local DHCP server, and optionally enables Ethernet WAN with NAT,
# but only when an Ethernet interface with carrier is detected while the script runs.
# Prueft/activeiert ausserdem SSH robust through TCP-Port 22/sshd und fragt interactive nach SSID, Passwort und Wireless country code.

set -o pipefail

SSID="${SSID:-Photobooth}"
PASSPHRASE="${PASSPHRASE:-photobooth}"
AP_ADDRESS="${AP_ADDRESS:-10.3.141.50/24}"
COUNTRY_CODE="${COUNTRY_CODE:-de}"
SSID_FROM_CLI=0
PASSPHRASE_FROM_CLI=0
COUNTRY_FROM_CLI=0
DHCP_NAME="${DHCP_NAME:-PHOTOBOOTH}"
DHCP_START="${DHCP_START:-10.3.141.51}"
DHCP_STOP="${DHCP_STOP:-10.3.141.250}"
DHCP_DNS="${DHCP_DNS:-1.1.1.1}"
DNS_FORWARD_1="${DNS_FORWARD_1:-1.1.1.1}"
DNS_FORWARD_2="${DNS_FORWARD_2:-8.8.8.8}"
WAN_ROUTE_DISTANCE="${WAN_ROUTE_DISTANCE:-1}"
FORCED_IF="${VYOS_IF:-}"
AP_IF_CACHE="${AP_IF_CACHE:-/config/photobooth-ap-interface.conf}"
OLD_UDEV_RULE="${OLD_UDEV_RULE:-/etc/udev/rules.d/70-vyos-ap-phy.rules}"
WAN_MODE="${WAN_MODE:-auto}"
FORCED_WAN_IF="${WAN_IF:-}"
NAT_RULE="${NAT_RULE:-150}"

usage() {
  cat <<USAGE
Usage: $0 [OPTIONS]

Options:
  --ssid NAME             SSID; unterdrueckt die Rueckfrage
                          (Standard bei leerer Eingabe: $SSID)
  --passphrase PASSWORT   WPA2-Passwort; unterdrueckt die Rueckfrage
                          (8 bis 63 Zeichen; Standard: $PASSPHRASE)
  --address CIDR          AP-Adresse (Standard: $AP_ADDRESS)
  --country CC            Wireless country code; unterdrueckt die Rueckfrage
                          (Standard bei leerer Eingabe: $COUNTRY_CODE)
  --interface NAME        VyOS-Interfacename erzwingen
  --dhcp-name NAME        DHCP Shared-Network-Name (Standard: $DHCP_NAME)
  --dhcp-start IP         Erste DHCP-Adresse (Standard: $DHCP_START)
  --dhcp-stop IP          Letzte DHCP-Adresse (Standard: $DHCP_STOP)
  --dns IP                An Clients ausgegebener DNS-Server (Standard: $DHCP_DNS)
  --wan auto|none|IFACE   Ethernet WAN: automatisch, aus oder Interface
                          (default: auto; enabled only when carrier is detected)
  --nat-rule NUMMER       VyOS-NAT-Regelnummer (Standard: $NAT_RULE)
  -h, --help              Hilfe

Das Skript richtet AP und DHCP immer ein. Bei --wan auto will be zusaetzlich nur
when a connected Ethernet interface is detected, a DHCP client and NAT are
configured. Without carrier, WAN is skipped cleanly while AP and DHCP remain active.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  builtin exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

# VyOS configuration scripts must run with the vyattacfg primary group.
# Re-exec before argument parsing so all CLI arguments are preserved.
if [ "$(id -g -n)" != "vyattacfg" ] && [ "${PI5_VYATTACFG_REEXEC:-0}" != "1" ]; then
  command -v sg >/dev/null 2>&1 || die "sg command is missing"
  SCRIPT_PATH="$(readlink -f "$0")"
  printf -v SCRIPT_Q '%q' "$SCRIPT_PATH"
  ARGS_Q=""
  for ARG in "$@"; do
    printf -v ARG_Q '%q' "$ARG"
    ARGS_Q+=" $ARG_Q"
  done
  export PI5_VYATTACFG_REEXEC=1
  exec sg vyattacfg -c "/bin/vbash $SCRIPT_Q$ARGS_Q"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssid) [ "$#" -ge 2 ] || die "Missing value for --ssid is missing"; SSID="$2"; SSID_FROM_CLI=1; shift 2 ;;
    --passphrase) [ "$#" -ge 2 ] || die "Missing value for --passphrase is missing"; PASSPHRASE="$2"; PASSPHRASE_FROM_CLI=1; shift 2 ;;
    --address) [ "$#" -ge 2 ] || die "Missing value for --address is missing"; AP_ADDRESS="$2"; shift 2 ;;
    --country) [ "$#" -ge 2 ] || die "Missing value for --country is missing"; COUNTRY_CODE="$2"; COUNTRY_FROM_CLI=1; shift 2 ;;
    --interface) [ "$#" -ge 2 ] || die "Missing value for --interface is missing"; FORCED_IF="$2"; shift 2 ;;
    --dhcp-name) [ "$#" -ge 2 ] || die "Missing value for --dhcp-name is missing"; DHCP_NAME="$2"; shift 2 ;;
    --dhcp-start) [ "$#" -ge 2 ] || die "Missing value for --dhcp-start is missing"; DHCP_START="$2"; shift 2 ;;
    --dhcp-stop) [ "$#" -ge 2 ] || die "Missing value for --dhcp-stop is missing"; DHCP_STOP="$2"; shift 2 ;;
    --dns) [ "$#" -ge 2 ] || die "Missing value for --dns is missing"; DHCP_DNS="$2"; shift 2 ;;
    --wan) [ "$#" -ge 2 ] || die "Missing value for --wan is missing"; WAN_MODE="$2"; shift 2 ;;
    --nat-rule) [ "$#" -ge 2 ] || die "Missing value for --nat-rule is missing"; NAT_RULE="$2"; shift 2 ;;
    -h|--help) usage; builtin exit 0 ;;
    *) die "Unbekannte Option: $1" ;;
  esac
done

[ -r /opt/vyatta/etc/functions/script-template ] || die "VyOS script-template not found"

need_cmd iw
need_cmd ip
need_cmd awk
need_cmd grep
need_cmd sed
need_cmd sort
need_cmd paste
need_cmd readlink
need_cmd python3
need_cmd find
need_cmd install
need_cmd mktemp
need_cmd sudo

if [ "$SSID_FROM_CLI" -eq 0 ]; then
  read -rp "Wireless SSID [$SSID]: " SSID_INPUT
  [ -z "$SSID_INPUT" ] || SSID="$SSID_INPUT"
fi

if [ "$PASSPHRASE_FROM_CLI" -eq 0 ]; then
  read -rsp "Wireless password [$PASSPHRASE]: " PASSPHRASE_INPUT
  echo ""
  [ -z "$PASSPHRASE_INPUT" ] || PASSPHRASE="$PASSPHRASE_INPUT"
fi

[ -n "$SSID" ] || die "SSID must not be empty"
case "$AP_ADDRESS" in */*) ;; *) die "--address muss CIDR enthalten" ;; esac
PASSLEN=${#PASSPHRASE}
[ "$PASSLEN" -ge 8 ] && [ "$PASSLEN" -le 63 ] || die "WPA2-Passwort muss 8 bis 63 Zeichen lang sein"

if [ "$COUNTRY_FROM_CLI" -eq 0 ]; then
  read -rp "Wireless country code [$COUNTRY_CODE]: " COUNTRY_INPUT
  [ -z "$COUNTRY_INPUT" ] || COUNTRY_CODE="$COUNTRY_INPUT"
fi
[[ "$COUNTRY_CODE" =~ ^[A-Za-z]{2}$ ]] || die "Country code muss aus genau zwei Buchstaben bestehen (z. B. de)"

COUNTRY_CODE="$(printf '%s' "$COUNTRY_CODE" | tr '[:upper:]' '[:lower:]')"
REG_COUNTRY="$(printf '%s' "$COUNTRY_CODE" | tr '[:lower:]' '[:upper:]')"
AP_GATEWAY="${AP_ADDRESS%/*}"
AP_PREFIX="${AP_ADDRESS#*/}"

AP_NET="$(python3 - "$AP_ADDRESS" <<'PY'
import ipaddress, sys
try:
    print(ipaddress.ip_interface(sys.argv[1]).network)
except ValueError as exc:
    print(exc, file=sys.stderr)
    raise SystemExit(1)
PY
)" || die "Invalide AP-Adresse: $AP_ADDRESS"

python3 - "$AP_NET" "$AP_GATEWAY" "$DHCP_START" "$DHCP_STOP" "$DHCP_DNS" <<'PY' || exit 1
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1])
gw = ipaddress.ip_address(sys.argv[2])
start = ipaddress.ip_address(sys.argv[3])
stop = ipaddress.ip_address(sys.argv[4])
dns = ipaddress.ip_address(sys.argv[5])
if gw not in net:
    raise SystemExit(f"ERROR: Gateway {gw} is not inside {net}")
if start not in net or stop not in net:
    raise SystemExit(f"ERROR: DHCP range is not fully inside {net}")
if int(start) > int(stop):
    raise SystemExit("ERROR: DHCP-Start ist groesser als DHCP-Stop")
if start == gw or stop == gw or int(start) <= int(gw) <= int(stop):
    raise SystemExit("ERROR: AP gateway must not be inside the DHCP range")
PY

sudo iw reg set "$REG_COUNTRY" 2>/dev/null || true
sleep 1

ssh_is_running() {
  if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:|\])22$'; then
    return 0
  fi

  if pgrep -x sshd >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

is_fm350_rndis_interface() {
  local iface="$1" dev vendor product driver
  [ -e "/sys/class/net/$iface/device" ] || return 1
  dev="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || true)"
  driver="$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver:/ {print $2; exit}')"
  [ "$driver" = "rndis_host" ] || return 1

  while [ -n "$dev" ] && [ "$dev" != "/" ]; do
    if [ -r "$dev/idVendor" ] && [ -r "$dev/idProduct" ]; then
      vendor="$(cat "$dev/idVendor" 2>/dev/null || true)"
      product="$(cat "$dev/idProduct" 2>/dev/null || true)"
      if [ "$vendor" = "0e8d" ] && { [ "$product" = "7126" ] || [ "$product" = "7127" ]; }; then
        return 0
      fi
    fi
    dev="${dev%/*}"
  done
  return 1
}

detect_connected_ethernet() {
  local iface path carrier oper type
  for path in /sys/class/net/*; do
    [ -e "$path" ] || continue
    iface="$(basename "$path")"
    case "$iface" in
      lo|wlan*|wl*|wwan*|mhi*|usb*|br*|bond*|dummy*|ifb*|veth*|tun*|tap*|pim*|sit*|ip6tnl*) continue ;;
    esac
    [ -e "$path/device" ] || continue
    type="$(cat "$path/type" 2>/dev/null || true)"
    [ "$type" = "1" ] || continue
    if is_fm350_rndis_interface "$iface"; then
      echo "NOTE: excluding $iface from Ethernet-WAN candidates (FM350 USB/RNDIS modem)." >&2
      continue
    fi
    carrier="$(cat "$path/carrier" 2>/dev/null || echo 0)"
    oper="$(cat "$path/operstate" 2>/dev/null || true)"
    if [ "$carrier" = "1" ] || [ "$oper" = "up" ]; then
      printf '%s\n' "$iface"
    fi
  done
}

select_wan_interface() {
  local candidates choice count iface
  case "$WAN_MODE" in
    none|off|disabled) printf ''; return 0 ;;
    auto) ;;
    *)
      iface="$WAN_MODE"
      [ -e "/sys/class/net/$iface" ] || die "WAN-Interface $iface does not exist"
      [ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo 0)" = "1" ] || {
        echo "NOTE: $iface has no carrier; WAN will be skipped." >&2
        printf ''
        return 0
      }
      printf '%s' "$iface"
      return 0
      ;;
  esac

  if [ -n "$FORCED_WAN_IF" ]; then
    iface="$FORCED_WAN_IF"
    [ -e "/sys/class/net/$iface" ] || die "WAN_IF=$iface does not exist"
    if [ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo 0)" = "1" ]; then
      printf '%s' "$iface"
    else
      echo "NOTE: $iface has no carrier; WAN will be skipped." >&2
      printf ''
    fi
    return 0
  fi

  mapfile -t candidates < <(detect_connected_ethernet)
  count="${#candidates[@]}"
  if [ "$count" -eq 0 ]; then
    printf ''
    return 0
  fi
  if [ "$count" -eq 1 ]; then
    printf '%s' "${candidates[0]}"
    return 0
  fi

  echo "" >&2
  echo "Multiple Ethernet ports with cable link detected:" >&2
  for i in "${!candidates[@]}"; do
    echo "  $((i+1))) ${candidates[$i]}" >&2
  done
  read -rp "Select WAN port: " choice </dev/tty
  [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalide WAN-Selection"
  [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ] || die "Invalide WAN-Selection"
  printf '%s' "${candidates[$((choice-1))]}"
}

phy_driver() {
  local phydir="$1" iface="$2" driver=""
  if [ -n "$iface" ] && command -v ethtool >/dev/null 2>&1; then
    driver="$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver:/ {print $2; exit}')"
  fi
  if [ -z "$driver" ] && [ -e "$phydir/device/driver" ]; then
    driver="$(basename "$(readlink -f "$phydir/device/driver")")"
  fi
  [ -n "$driver" ] || driver="unknown"
  printf '%s' "$driver"
}

phy_bus() {
  case "$1" in
    *'/usb'*) printf 'USB' ;;
    *'/pci'*) printf 'PCIe' ;;
    *'/mmc'*) printf 'SDIO' ;;
    *'/platform'*) printf 'Platform' ;;
    *) printf '?' ;;
  esac
}

phy_has_ap() {
  printf '%s\n' "$1" |
    sed -n '/Supported interface modes:/,/^[[:space:]]*Band [0-9][0-9]*:/p' |
    grep -Eq '^[[:space:]]*\*[[:space:]]+AP[[:space:]]*$'
}

band_numbers() {
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*Band \([0-9][0-9]*\):.*/\1/p'
}

band_block() {
  printf '%s\n' "$1" | awk -v n="$2" '
    $0 ~ "^[[:space:]]*Band " n ":" {inside=1; print; next}
    inside && $0 ~ "^[[:space:]]*Band [0-9]+:" {exit}
    inside {print}
  '
}

usable_channels() {
  printf '%s\n' "$1" | awk -v lo="$2" -v hi="$3" '
    $1 == "*" && $3 == "MHz" {
      line=tolower($0); freq=$2+0; channel=$4
      gsub(/\[/, "", channel); gsub(/\]/, "", channel)
      if (freq >= lo && freq <= hi && line !~ /disabled/ && line !~ /no ir/ && line !~ /radar detection/) print channel
    }
  ' | sort -n -u | paste -sd' ' -
}

contains_channel() {
  case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

pick_default_channel() {
  if contains_channel "$1" "$2"; then
    printf '%s' "$2"
  else
    printf '%s\n' "$1" | awk '{print $1}'
  fi
}

first_phy_interface() {
  local phy="$1" iface=""
  iface="$(iw dev 2>/dev/null | awk -v p="$phy" '
    $1=="phy#" substr(p,4) {inside=1; next}
    /^phy#/ {inside=0}
    inside && $1=="Interface" {print $2; exit}
  ')"
  if [ -z "$iface" ]; then
    iface="$(find "/sys/class/ieee80211/$phy/device/net" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -1)"
  fi
  [ -n "$iface" ] || return 1
  printf '%s' "$iface"
}

next_free_wlan() {
  local n
  for n in $(seq 0 31); do
    [ -e "/sys/class/net/wlan$n" ] || { printf 'wlan%s' "$n"; return 0; }
  done
  return 1
}

declare -a PHYS MACS DRIVERS BUSES IFACES INFOS SUMMARIES SELECTABLE

for phydir in /sys/class/ieee80211/phy*; do
  [ -d "$phydir" ] || continue
  phy="$(basename "$phydir")"
  mac="$(cat "$phydir/macaddress" 2>/dev/null || true)"
  [ -n "$mac" ] || continue
  iface="$(first_phy_interface "$phy" 2>/dev/null || true)"
  driver="$(phy_driver "$phydir" "$iface")"
  bus="$(phy_bus "$(readlink -f "$phydir/device" 2>/dev/null || true)")"
  info="$(iw phy "$phy" info 2>/dev/null || true)"
  summary="no AP mode"

  if [ -n "$info" ] && phy_has_ap "$info"; then
    ch2=""; ch5=""
    while read -r bnum; do
      [ -n "$bnum" ] || continue
      block="$(band_block "$info" "$bnum")"
      [ -n "$(usable_channels "$block" 2400 2500)" ] && ch2=1
      [ -n "$(usable_channels "$block" 4900 5924)" ] && ch5=1
    done < <(band_numbers "$info")
    summary=""
    [ -n "$ch2" ] && summary="${summary}2.4GHz "
    [ -n "$ch5" ] && summary="${summary}5GHz "
    [ -n "$summary" ] || summary="none nutzbaren AP-Kanaele"
  fi

  PHYS+=("$phy")
  MACS+=("$mac")
  DRIVERS+=("$driver")
  BUSES+=("$bus")
  IFACES+=("${iface:--}")
  INFOS+=("$info")
  SUMMARIES+=("$summary")
done

[ "${#PHYS[@]}" -gt 0 ] || die "No wireless PHY found"

echo ""
printf '%-4s %-8s %-8s %-14s %-19s %-10s %s\n' Nr PHY Bus driver MAC Interface 'AP bands'
for i in "${!PHYS[@]}"; do
  printf '%-4s %-8s %-8s %-14s %-19s %-10s %s\n' \
    "$((i+1))" "${PHYS[$i]}" "${BUSES[$i]}" "${DRIVERS[$i]}" \
    "${MACS[$i]}" "${IFACES[$i]}" "${SUMMARIES[$i]}"
  [[ "${SUMMARIES[$i]}" == *GHz* ]] && SELECTABLE+=("$i")
done

[ "${#SELECTABLE[@]}" -gt 0 ] || die "No wireless device with usable AP mode found"

echo ""
echo "Select AP device:"
for i in "${SELECTABLE[@]}"; do
  echo "  $((i+1))) ${PHYS[$i]}  ${BUSES[$i]}  ${DRIVERS[$i]}  ${MACS[$i]}  Interface ${IFACES[$i]}  ${SUMMARIES[$i]}"
done
read -rp "Selection: " CHOICE
[[ "$CHOICE" =~ ^[0-9]+$ ]] || die "Invalide Selection"
IDX=$((CHOICE-1))
valid=0
for i in "${SELECTABLE[@]}"; do [ "$i" -eq "$IDX" ] && valid=1; done
[ "$valid" -eq 1 ] || die "Device is not selectable"

PHY="${PHYS[$IDX]}"
MAC="${MACS[$IDX]}"
DRIVER="${DRIVERS[$IDX]}"
BUS="${BUSES[$IDX]}"
PHYINFO="${INFOS[$IDX]}"
EXISTING_IF="${IFACES[$IDX]}"

CH2=""; CH5=""; HT2=0; HT5=0; VHT5=0; HE2=0; HE5=0
while read -r bnum; do
  [ -n "$bnum" ] || continue
  BLOCK="$(band_block "$PHYINFO" "$bnum")"
  B2="$(usable_channels "$BLOCK" 2400 2500)"
  B5="$(usable_channels "$BLOCK" 4900 5924)"
  if [ -n "$B2" ]; then
    CH2="$B2"
    printf '%s\n' "$BLOCK" | grep -Eq '^[[:space:]]*(HT Capabilities|HT Max RX data rate|HT TX/RX MCS rate indexes supported|HT MCS set)' && HT2=1
    printf '%s\n' "$BLOCK" | grep -Eq 'HE Iftypes:.*AP' && HE2=1
  fi
  if [ -n "$B5" ]; then
    CH5="$B5"
    printf '%s\n' "$BLOCK" | grep -Eq '^[[:space:]]*(HT Capabilities|HT Max RX data rate|HT TX/RX MCS rate indexes supported|HT MCS set)' && HT5=1
    printf '%s\n' "$BLOCK" | grep -q 'VHT Capabilities' && VHT5=1
    printf '%s\n' "$BLOCK" | grep -Eq 'HE Iftypes:.*AP' && HE5=1
  fi
done < <(band_numbers "$PHYINFO")

declare -a LABELS MODES CHANNELS DEFAULTS
if [ -n "$CH2" ]; then
  if [ "$HE2" -eq 1 ]; then
    LABELS+=("2.4GHz WiFi 6 / 802.11ax"); MODES+=("ax")
  elif [ "$HT2" -eq 1 ]; then
    LABELS+=("2.4GHz / 802.11n"); MODES+=("n")
  else
    LABELS+=("2.4GHz / 802.11g"); MODES+=("g")
  fi
  CHANNELS+=("$CH2"); DEFAULTS+=("$(pick_default_channel "$CH2" 6)")
fi
if [ -n "$CH5" ]; then
  # Prefer the proven VyOS 5 GHz 802.11ac path even if the PHY also advertises HE/AX.
  # Keep the proven conservative 5 GHz ac path until HE/AX behavior is validated on Raspberry Pi 5 hardware;
  # ac + VHT80 is stable and reaches 80 MHz with 2x2 client links when negotiated.
  if [ "$VHT5" -eq 1 ]; then
    LABELS+=("5GHz Fast / 802.11ac / 80MHz"); MODES+=("ac")
  elif [ "$HT5" -eq 1 ]; then
    LABELS+=("5GHz / 802.11n"); MODES+=("n")
  else
    LABELS+=("5GHz / 802.11a"); MODES+=("a")
  fi
  CHANNELS+=("$CH5"); DEFAULTS+=("$(pick_default_channel "$CH5" 36)")
fi

[ "${#LABELS[@]}" -gt 0 ] || die "No AP-Option verfuegbar"
echo ""
echo "Select band and mode:"
for i in "${!LABELS[@]}"; do echo "  $((i+1))) ${LABELS[$i]}"; done
read -rp "Selection: " BCH
[[ "$BCH" =~ ^[0-9]+$ ]] || die "Invalide Selection"
BIDX=$((BCH-1))
[ -n "${LABELS[$BIDX]:-}" ] || die "Invalide Selection"
WLAN_MODE="${MODES[$BIDX]}"
CHANNEL_LIST="${CHANNELS[$BIDX]}"
CHANNEL="${DEFAULTS[$BIDX]}"
echo "Usable channels: $CHANNEL_LIST"
read -rp "Channel [$CHANNEL]: " CH_INPUT
if [ -n "$CH_INPUT" ]; then
  [[ "$CH_INPUT" =~ ^[0-9]+$ ]] || die "Channel must be numeric"
  contains_channel "$CHANNEL_LIST" "$CH_INPUT" || die "Channel $CH_INPUT is not usable"
  CHANNEL="$CH_INPUT"
fi

if [ -n "$FORCED_IF" ]; then
  VYOS_IF="$FORCED_IF"
elif [ "$EXISTING_IF" != "-" ]; then
  VYOS_IF="$EXISTING_IF"
else
  VYOS_IF="$(next_free_wlan)" || die "No free wlan interface name found"
fi

OLD_AP_IF=""
OLD_AP_MAC=""
if [ -r "$AP_IF_CACHE" ]; then
  OLD_AP_IF="$(sed -n "s/^AP_IF=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" "$AP_IF_CACHE" | head -1)"
  OLD_AP_MAC="$(sed -n "s/^AP_MAC=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" "$AP_IF_CACHE" | head -1)"
fi

sudo rm -f "$OLD_UDEV_RULE"
command -v udevadm >/dev/null 2>&1 && sudo udevadm control --reload-rules 2>/dev/null || true

echo ""
echo "Selected: $PHY / $DRIVER / $BUS / MAC $MAC"
echo "VyOS-Interface: $VYOS_IF"
echo "AP: SSID '$SSID', mode $WLAN_MODE, channel $CHANNEL, address $AP_ADDRESS, country $REG_COUNTRY"
[ "$WLAN_MODE" = "ac" ] && echo "5GHz profile: AC80 stable (HT40+ / VHT80 / short-GI 80)"
echo "DHCP: $DHCP_START bis $DHCP_STOP, Gateway $AP_GATEWAY, Netz $AP_NET"
WAN_IF_SELECTED="$(select_wan_interface)"
if [ -n "$WAN_IF_SELECTED" ]; then
  echo "Ethernet WAN: $WAN_IF_SELECTED (carrier detected; DHCP client and NAT will be configured)"
else
  echo "Ethernet WAN: no carrier detected or WAN disabled; skipping WAN without error."
fi
if [ -n "$OLD_AP_MAC" ] && [ "$OLD_AP_MAC" != "$MAC" ]; then
  echo "Vorheriger AP-Adapter will be ersetzt: $OLD_AP_MAC -> $MAC"
fi
echo "Applying AP, DHCP, SSH, and optional Ethernet WAN in separate safe commits ..."

SSH_WAS_ACTIVE=0
if ssh_is_running; then
  SSH_WAS_ACTIVE=1
  echo "SSH: the server is already listening on TCP port 22; the VyOS configuration will be persisted."
else
  echo "SSH: no running SSH server detected; SSH will be enabled in the VyOS configuration."
fi

source /opt/vyatta/etc/functions/script-template
configure

echo "[1/2] Removing all previous wireless configuration ..."
for N in $(seq 0 31); do
  delete interfaces wireless "wlan$N" 2>/dev/null || true
done

set system wireless country-code "$COUNTRY_CODE"
set service ssh
set interfaces wireless "$VYOS_IF" physical-device "$PHY"
set interfaces wireless "$VYOS_IF" address "$AP_ADDRESS"
set interfaces wireless "$VYOS_IF" type 'access-point'
set interfaces wireless "$VYOS_IF" ssid "$SSID"
set interfaces wireless "$VYOS_IF" channel "$CHANNEL"
set interfaces wireless "$VYOS_IF" mode "$WLAN_MODE"

# Proven fast 5 GHz profile: explicit VHT80 geometry.
# The usable-channel filter already excludes DFS/radar channels; in DE this normally
# leaves 36/40/44/48, all belonging to the 80 MHz block centered on channel 42.
if [ "$WLAN_MODE" = "ac" ]; then
  case "$CHANNEL" in
    36|40|44|48) VHT_CENTER=42 ;;
    52|56|60|64) VHT_CENTER=58 ;;
    100|104|108|112) VHT_CENTER=106 ;;
    116|120|124|128) VHT_CENTER=122 ;;
    132|136|140|144) VHT_CENTER=138 ;;
    149|153|157|161) VHT_CENTER=155 ;;
    *) VHT_CENTER="" ;;
  esac

  if [ -n "$VHT_CENTER" ]; then
    set interfaces wireless "$VYOS_IF" capabilities ht channel-set-width 'ht40+'
    set interfaces wireless "$VYOS_IF" capabilities vht channel-set-width '1'
    set interfaces wireless "$VYOS_IF" capabilities vht center-channel-freq freq-1 "$VHT_CENTER"
    set interfaces wireless "$VYOS_IF" capabilities vht short-gi '80'
  else
    echo "WARNING: Channel $CHANNEL has no known 80 MHz center mapping; using plain 802.11ac without forced VHT80." >&2
  fi
fi

set interfaces wireless "$VYOS_IF" security wpa mode 'wpa2'
set interfaces wireless "$VYOS_IF" security wpa cipher 'CCMP'
set interfaces wireless "$VYOS_IF" security wpa passphrase "$PASSPHRASE"

echo "[1/2] Committing AP configuration ..."
if ! commit; then
  echo "ERROR: AP commit failed. Changes will be discarded." >&2
  discard
  builtin exit 1
fi
save
echo "[1/2] AP saved."

echo "[2/2] Configuring DHCP ..."
delete service dhcp-server shared-network-name "$DHCP_NAME" 2>/dev/null || true
set service dhcp-server shared-network-name "$DHCP_NAME" authoritative
set service dhcp-server shared-network-name "$DHCP_NAME" subnet "$AP_NET" subnet-id '1'
set service dhcp-server shared-network-name "$DHCP_NAME" subnet "$AP_NET" option default-router "$AP_GATEWAY"
set service dhcp-server shared-network-name "$DHCP_NAME" subnet "$AP_NET" option name-server "$DHCP_DNS"
set service dhcp-server shared-network-name "$DHCP_NAME" subnet "$AP_NET" option name-server "$AP_GATEWAY"
set service dhcp-server shared-network-name "$DHCP_NAME" subnet "$AP_NET" range 0 start "$DHCP_START"
set service dhcp-server shared-network-name "$DHCP_NAME" subnet "$AP_NET" range 0 stop "$DHCP_STOP"

# Reproduce the known-good DNS forwarding setup from config.boot.
delete service dns forwarding 2>/dev/null || true
set service dns forwarding allow-from "$AP_NET"
set service dns forwarding listen-address "$AP_GATEWAY"
set service dns forwarding name-server "$DNS_FORWARD_1"
set service dns forwarding name-server "$DNS_FORWARD_2"

# Reproduce the known-good AP -> WAN forward policy.
# Rule 20 sends traffic arriving from the AP to an accept chain.
delete firewall ipv4 forward filter rule 20 2>/dev/null || true
delete firewall ipv4 name PHOTOBOOTH-AP-OUT 2>/dev/null || true
set firewall ipv4 name PHOTOBOOTH-AP-OUT default-action 'accept'
set firewall ipv4 forward filter rule 20 action 'jump'
set firewall ipv4 forward filter rule 20 inbound-interface name "$VYOS_IF"
set firewall ipv4 forward filter rule 20 jump-target 'PHOTOBOOTH-AP-OUT'

echo "[2/2] Committing DHCP configuration ..."
if ! commit; then
  echo "ERROR: DHCP-Commit failed. The AP is already saved; only DHCP changes will be discarded." >&2
  discard
  builtin exit 1
fi
save
echo "[2/2] DHCP saved."

WAN_CONFIGURED=0
if [ -n "$WAN_IF_SELECTED" ]; then
  echo "[3/3] Ethernet WAN $WAN_IF_SELECTED configuring ..."

  # Ethernet is the primary WAN. Keep this ownership in the AP/WAN script;
  # modem-connect.sh must never rewrite it.
  set interfaces ethernet "$WAN_IF_SELECTED" address 'dhcp'
  set interfaces ethernet "$WAN_IF_SELECTED" description 'WAN-LAN-DHCP'
  set interfaces ethernet "$WAN_IF_SELECTED" dhcp-options default-route-distance "$WAN_ROUTE_DISTANCE"

  # Remove the legacy duplicate Ethernet NAT rule created by older modem scripts.
  if [ "$NAT_RULE" != "100" ]; then
    delete nat source rule 100 2>/dev/null || true
  fi
  delete nat source rule "$NAT_RULE" 2>/dev/null || true
  set nat source rule "$NAT_RULE" description 'AP-NET-to-WIRED-WAN'
  set nat source rule "$NAT_RULE" outbound-interface name "$WAN_IF_SELECTED"
  set nat source rule "$NAT_RULE" source address "$AP_NET"
  set nat source rule "$NAT_RULE" translation address 'masquerade'

  # WAN -> router/AP forwarding: only established/related return traffic.
  delete firewall ipv4 forward filter rule 10 2>/dev/null || true
  delete firewall ipv4 name PHOTOBOOTH-WAN-IN 2>/dev/null || true
  set firewall ipv4 name PHOTOBOOTH-WAN-IN default-action 'drop'
  set firewall ipv4 name PHOTOBOOTH-WAN-IN rule 10 action 'accept'
  set firewall ipv4 name PHOTOBOOTH-WAN-IN rule 10 state 'established'
  set firewall ipv4 name PHOTOBOOTH-WAN-IN rule 10 state 'related'
  set firewall ipv4 forward filter rule 10 action 'jump'
  set firewall ipv4 forward filter rule 10 inbound-interface name "$WAN_IF_SELECTED"
  set firewall ipv4 forward filter rule 10 jump-target 'PHOTOBOOTH-WAN-IN'

  echo "[3/3] Committing Ethernet WAN/NAT ..."
  if ! commit; then
    echo "WARNING: WAN/NAT commit failed. AP and DHCP remain saved." >&2
    discard
  else
    save
    WAN_CONFIGURED=1
    echo "[3/3] Ethernet WAN/NAT saved."
  fi
else
  echo "[3/3] No verbundenes Ethernet WAN: Schritt throughsprungen."
fi

CACHE_TMP="$(mktemp)"
cat > "$CACHE_TMP" <<CACHE
AP_IF='$VYOS_IF'
AP_MAC='$MAC'
AP_SSID='$SSID'
AP_ADDRESS='$AP_ADDRESS'
COUNTRY_CODE='$COUNTRY_CODE'
DHCP_NAME='$DHCP_NAME'
DHCP_START='$DHCP_START'
DHCP_STOP='$DHCP_STOP'
WAN_IF='$WAN_IF_SELECTED'
NAT_RULE='$NAT_RULE'
WAN_ROUTE_DISTANCE='$WAN_ROUTE_DISTANCE'
DNS_FORWARD_1='$DNS_FORWARD_1'
DNS_FORWARD_2='$DNS_FORWARD_2'
CACHE
install -m 0600 "$CACHE_TMP" "$AP_IF_CACHE"
rm -f "$CACHE_TMP"

READY_AP=0
READY_DHCP=0
for _ in $(seq 1 45); do
  if ip addr show "$VYOS_IF" 2>/dev/null | grep -q "inet ${AP_GATEWAY}/"; then
    if systemctl is-active --quiet "hostapd@${VYOS_IF}.service" 2>/dev/null || pgrep -f "hostapd.*${VYOS_IF}" >/dev/null 2>&1; then
      READY_AP=1
    fi
  fi
  if ss -lun 2>/dev/null | awk -v ip="$AP_GATEWAY" '$4 == ip ":67" || $4 == "0.0.0.0:67" || $4 == "*:67" {found=1} END {exit !found}'; then
    READY_DHCP=1
  elif systemctl is-active --quiet isc-kea-dhcp4-server.service 2>/dev/null || systemctl is-active --quiet kea-dhcp4-server.service 2>/dev/null; then
    READY_DHCP=1
  fi
  [ "$READY_AP" -eq 1 ] && [ "$READY_DHCP" -eq 1 ] && break
  sleep 1
done

echo ""
if [ "$READY_AP" -eq 1 ]; then
  echo "PASS: AP '$SSID' is active on $VYOS_IF (${AP_GATEWAY}/${AP_PREFIX}, channel $CHANNEL, mode $WLAN_MODE)."
else
  echo "WARNING: The AP was saved but was not fully active after 45 seconds."
  echo "Check: ip -br addr show $VYOS_IF"
  echo "Check: systemctl status hostapd@${VYOS_IF}.service --no-pager -l"
fi

if [ "$READY_DHCP" -eq 1 ]; then
  echo "PASS: DHCP is listening on UDP port 67; range $DHCP_START-$DHCP_STOP."
else
  echo "WARNING: DHCP was saved, but UDP port 67 was not listening within 45 seconds."
  echo "Check: sudo ss -lunp | grep ':67'"
  echo "Check: sudo systemctl list-units --type=service | grep -Ei 'dhcp|kea'"
fi

if [ -n "$WAN_IF_SELECTED" ]; then
  if [ "$WAN_CONFIGURED" -eq 1 ]; then
    echo "PASS: Optional Ethernet WAN is configured on $WAN_IF_SELECTED as a DHCP client with NAT rule $NAT_RULE saved."
    echo "Note: An IPv4 address/default route appears only when the connected router provides DHCP."
  else
    echo "WARNING: Ethernet carrier was present, but WAN/NAT could not be saved. AP and DHCP remain operational."
  fi
else
  echo "INFO: No Ethernet carrier was present while the script ran. AP and DHCP were still configured completely."
  echo "To enable Ethernet WAN later, connect a cable and run the script again."
fi

if ssh_is_running; then
  echo "PASS: SSH server is running and listening on TCP port 22."
else
  echo "WARNING: 'service ssh' is saved, but no SSH server was detected on TCP port 22."
  echo "Check: show configuration commands | match 'service ssh'"
  echo "Check: sudo ss -ltnp | grep ':22'"
  echo "Check: pgrep -a sshd"
fi

echo "Wireless country code: $REG_COUNTRY"
echo "Detected AP adapter: $VYOS_IF -> $MAC (MAC is not stored as VyOS hw-id)"
echo "Cache: $AP_IF_CACHE"
builtin exit 0
