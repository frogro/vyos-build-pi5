#!/bin/bash
# Run the VyOS configuration script, then restart the DHCP client in its own
# systemd service so it is not terminated when the configuration session ends.

set -euo pipefail

LOG="/config/dhcp-wan-firstboot-wrapper.log"
MARKER="/config/.dhcp-wan-ssh-firstboot-done"
IFACE_FILE="/config/.dhcp-wan-interface"
SETUP="/home/vyos/dhcp-wan-ssh-setup.sh"
TIMER="pi5-dhcp-wan-firstboot.timer"

exec >>"$LOG" 2>&1

log() {
    printf '%s %s\n' "$(date -Is)" "pi5-dhcp-wan-wrapper: $*"
}

fail() {
    log "FEHLER: $*"
    exit 1
}

[ -e "$MARKER" ] && exit 0

log "Starte VyOS-Konfigurationsskript"

/usr/sbin/runuser -u vyos -- /bin/vbash -lc "$SETUP --auto"

[ -r "$IFACE_FILE" ] || fail "Interface-Datei fehlt: $IFACE_FILE"
IFACE="$(cat "$IFACE_FILE")"
[ -e "/sys/class/net/$IFACE" ] || fail "Interface $IFACE existiert nicht"

log "Konfiguration beendet; starte dhclient@${IFACE}.service ausserhalb der Konfigurationssitzung neu"

/bin/systemctl reset-failed "dhclient@${IFACE}.service" 2>/dev/null || true
/bin/systemctl restart "dhclient@${IFACE}.service"

IPV4=""
for _ in $(seq 1 60); do
    IPV4="$(ip -4 -br address show dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')"
    [ -n "$IPV4" ] && break
    sleep 2
done

[ -n "$IPV4" ] || fail "$IFACE erhielt nach dem dhclient-Neustart keine IPv4-Adresse"
log "$IFACE behaelt IPv4 $IPV4"

DEFAULT_ROUTE=""
for _ in $(seq 1 30); do
    DEFAULT_ROUTE="$(ip -4 route show default dev "$IFACE" 2>/dev/null | head -1)"
    [ -n "$DEFAULT_ROUTE" ] && break
    sleep 2
done

[ -n "$DEFAULT_ROUTE" ] || fail "$IFACE erhielt per DHCP keine IPv4-Default-Route"
log "Default-Route aktiv: $DEFAULT_ROUTE"

if ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:|\])22$'; then
    for SSH_UNIT in ssh@default.service ssh.service sshd.service; do
        if /bin/systemctl cat "$SSH_UNIT" >/dev/null 2>&1; then
            /bin/systemctl restart "$SSH_UNIT" || true
            break
        fi
    done
fi

for _ in $(seq 1 30); do
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:|\])22$'; then
        touch "$MARKER"
        chmod 600 "$MARKER"
        log "FERTIG: $IFACE=$IPV4, DHCP-Client aktiv, SSH lauscht auf Port 22"
        /bin/systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
        exit 0
    fi
    sleep 1
done

fail "SSH lauscht nicht auf Port 22"
