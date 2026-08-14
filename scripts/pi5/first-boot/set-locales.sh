#!/bin/vbash
#
# Configure locale, time zone, DNS, NTP, and wireless regulatory domain on VyOS.
# Optimized: persistent C.UTF-8 is applied even when no VyOS config changes are needed.
#
# Run as the "vyos" user:
#   chmod +x /home/vyos/set-locales.sh
#   /home/vyos/set-locales.sh
#
# Do not run with sudo, sudo bash, or bash.

set -o pipefail

# Use a UTF-8 locale that is guaranteed to exist in the VyOS image.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

if [ "$(id -u)" -eq 0 ]; then
    echo 'Please run this script as the "vyos" user, not as root.'
    builtin exit 1
fi

[ -r /opt/vyatta/etc/functions/script-template ] || {
    echo 'ERROR: VyOS script-template was not found.' >&2
    builtin exit 1
}

source /opt/vyatta/etc/functions/script-template

DEFAULT_TZ="Europe/Berlin"
DEFAULT_KEYBOARD="de"
DEFAULT_WIFI_COUNTRY="de"
DEFAULT_DNS1="1.1.1.1"
DEFAULT_DNS2="9.9.9.9"
DEFAULT_NTP1="time.cloudflare.com"
DEFAULT_NTP2="time.google.com"
UPDATE_CHECK_URL="https://raw.githubusercontent.com/frogro/vyos-build-pi5/rolling/version.json"
SYNC_TIMEOUT="${SYNC_TIMEOUT:-90}"

UPDATE_CHECK_ALREADY_SET=0
if /opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands 2>/dev/null | \
    grep -Fqx "set system update-check url '$UPDATE_CHECK_URL'"; then
    UPDATE_CHECK_ALREADY_SET=1
fi

ask_default() {
    local prompt="$1" default="$2" answer=""
    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" answer=""
    read -r -p "$prompt [$default]: " answer
    answer="${answer:-$default}"
    case "$answer" in
        y|Y|yes|Yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

fail() {
    echo "ERROR: $*" >&2
    builtin exit 1
}

echo '=== VyOS locale, time, DNS, NTP, and wireless setup ==='
echo 'Note: committing may briefly restart an active wireless access point.'
echo

TZ_VALUE="$(ask_default 'Time zone' "$DEFAULT_TZ")"
KEYBOARD_VALUE="$(ask_default 'Console keyboard layout' "$DEFAULT_KEYBOARD")"
WIFI_COUNTRY_VALUE="$(ask_default 'Wireless regulatory country code' "$DEFAULT_WIFI_COUNTRY")"
DNS1="$(ask_default 'Primary DNS server' "$DEFAULT_DNS1")"
DNS2="$(ask_default 'Secondary DNS server' "$DEFAULT_DNS2")"
NTP1="$(ask_default 'Primary NTP server' "$DEFAULT_NTP1")"
NTP2="$(ask_default 'Secondary NTP server' "$DEFAULT_NTP2")"

echo
echo "Time zone:       $TZ_VALUE"
echo "Keyboard layout: $KEYBOARD_VALUE"
echo "Wireless country: $WIFI_COUNTRY_VALUE"
echo "DNS servers:     $DNS1, $DNS2"
echo "NTP servers:     $NTP1, $NTP2"
if [ "$UPDATE_CHECK_ALREADY_SET" -eq 1 ]; then
    echo "Update channel:  Raspberry Pi rolling/latest (already set)"
else
    echo "Update channel:  Raspberry Pi rolling/latest (will be set)"
fi
echo "Update metadata: $UPDATE_CHECK_URL"
echo

if ! ask_yes_no 'Apply these settings?' 'y'; then
    echo 'Cancelled.'
    builtin exit 0
fi

configure || fail 'Could not enter configuration mode.'

CONFIG_FAILED=0
set system time-zone "$TZ_VALUE" || CONFIG_FAILED=1
set system option keyboard-layout "$KEYBOARD_VALUE" || CONFIG_FAILED=1
set system wireless country-code "$WIFI_COUNTRY_VALUE" || CONFIG_FAILED=1
delete system name-server 2>/dev/null || true
delete service ntp server 2>/dev/null || true
set system name-server "$DNS1" || CONFIG_FAILED=1
set system name-server "$DNS2" || CONFIG_FAILED=1
set service ntp server "$NTP1" || CONFIG_FAILED=1
set service ntp server "$NTP2" || CONFIG_FAILED=1
set system update-check url "$UPDATE_CHECK_URL" || CONFIG_FAILED=1

if [ "$CONFIG_FAILED" -ne 0 ]; then
    echo 'ERROR: At least one configuration command failed.' >&2
    discard
    builtin exit 1
fi

echo
echo '=== Proposed changes ==='
CHANGES="$(compare 2>/dev/null || true)"
printf '%s\n' "$CHANGES"

NO_CONFIG_CHANGES=0
if [ -z "$CHANGES" ] || printf '%s\n' "$CHANGES" | grep -q '^No changes between working and active configurations\.$'; then
    discard 2>/dev/null || true
    exit
    NO_CONFIG_CHANGES=1
    echo 'No VyOS configuration changes were required.'
else
    echo
fi

if [ "$NO_CONFIG_CHANGES" -eq 0 ]; then
    if ! ask_yes_no 'Commit and save? An active access point may restart briefly.' 'y'; then
        discard
        echo 'Cancelled; no changes were applied.'
        builtin exit 0
    fi

    if ! commit; then
        echo 'ERROR: Commit failed; discarding changes.' >&2
        discard
        builtin exit 1
    fi

    if ! save; then
        echo 'ERROR: Save failed.' >&2
        discard 2>/dev/null || true
        builtin exit 1
    fi

    # Leave VyOS configuration mode; script execution continues.
    exit
fi

echo
echo 'Persisting the system locale as C.UTF-8...'

if ! printf '%s\n' 'LANG=C.UTF-8' 'LC_ALL=C.UTF-8' | sudo tee /etc/default/locale >/dev/null; then
    echo 'WARNING: Could not write /etc/default/locale.' >&2
fi

if ! printf '%s\n' 'LANG=C.UTF-8' 'LC_ALL=C.UTF-8' | sudo tee /etc/environment >/dev/null; then
    echo 'WARNING: Could not write /etc/environment.' >&2
fi

if sudo install -d -m 0755 /etc/systemd/system.conf.d; then
    if ! printf '%s\n' '[Manager]' 'DefaultEnvironment=LANG=C.UTF-8 LC_ALL=C.UTF-8' | sudo tee /etc/systemd/system.conf.d/10-pi5-locale.conf >/dev/null; then
        echo 'WARNING: Could not write the systemd locale configuration.' >&2
    fi
else
    echo 'WARNING: Could not create /etc/systemd/system.conf.d.' >&2
fi

echo
echo 'Configuration saved. Restarting Chrony...'
if ! sudo systemctl restart chrony; then
    echo 'WARNING: Chrony could not be restarted.' >&2
fi

sleep 2
sudo chronyc makestep >/dev/null 2>&1 || true

echo "Waiting up to ${SYNC_TIMEOUT} seconds for NTP synchronization..."
SYNCED=no
ELAPSED=0
while [ "$ELAPSED" -lt "$SYNC_TIMEOUT" ]; do
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then
        SYNCED=yes
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

echo
echo '=== Time status ==='
date
timedatectl status | sed -n '1,8p'

echo
echo '=== Chrony tracking ==='
chronyc tracking || true

echo
echo '=== NTP sources ==='
chronyc sources -v || true

echo
if [ "$SYNCED" = yes ]; then
    echo 'Done: system time is synchronized.'
else
    echo "WARNING: NTP synchronization was not confirmed within ${SYNC_TIMEOUT} seconds."
    echo 'Check again later with: chronyc tracking'
fi
