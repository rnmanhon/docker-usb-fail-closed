#!/bin/bash
# Install or remove the host-level guard for a removable data disk.
#
#   sudo ./host/install.sh --mount /mnt/project-data [--usb VENDOR:PRODUCT:SERIAL]
#   sudo ./host/install.sh --mount /mnt/project-data --uninstall
#
# Installs:
#   /usr/local/sbin/project-data-guard-stop          stop helper
#   /etc/systemd/system/project-data-guard.service   bound to the mount unit, enabled WantedBy it
#   /etc/profile.d/project-data-status.sh            new-shell warning (+ one line in /etc/bash.bashrc)
#   /etc/udev/rules.d/90-project-data-usb-power.rules  only with --usb: USB autosuspend off for that disk
#
# Prerequisite: an /etc/fstab entry for the mountpoint (see examples/fstab.example).
# Find --usb values with: udevadm info -a -n /dev/sdX | grep -E 'ATTRS\{(idVendor|idProduct|serial)\}' | head -3
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
MNT="" USB="" ACTION=install
while (( $# )); do
    case "$1" in
        --mount) MNT="${2%/}"; shift 2 ;;
        --usb) USB="$2"; shift 2 ;;
        --uninstall) ACTION=uninstall; shift ;;
        *) echo "usage: sudo $0 --mount /mnt/data [--usb VENDOR:PRODUCT:SERIAL] [--uninstall]" >&2; exit 2 ;;
    esac
done
[[ "$MNT" == /?* ]] || { echo "--mount /absolute/mountpoint is required" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

UNIT=project-data-guard.service
MOUNT_UNIT="$(systemd-escape --path --suffix=mount "$MNT")"
STOP_BIN=/usr/local/sbin/project-data-guard-stop
STATUS_SH=/etc/profile.d/project-data-status.sh
UDEV_RULE=/etc/udev/rules.d/90-project-data-usb-power.rules
BASHRC=/etc/bash.bashrc
HOOK_MARK='# project-data-status (docker-usb-fail-closed)'
HOOK_LINE="[ -r $STATUS_SH ] && . $STATUS_SH"
say() { echo "==> $*"; }

install_all() {
    awk -v m="$MNT" '$1 !~ /^#/ && $2 == m { f = 1 } END { exit !f }' /etc/fstab ||
        { echo "No /etc/fstab entry for $MNT; add one first (examples/fstab.example)." >&2; exit 1; }

    install -m 0755 "$HERE/project-data-guard-stop.sh" "$STOP_BIN"
    sed -e "s#@MOUNTPOINT@#$MNT#g" -e "s#@MOUNT_UNIT@#${MOUNT_UNIT//\\/\\\\}#g" \
        "$HERE/project-data-guard.service.in" > "/etc/systemd/system/$UNIT"
    chmod 0644 "/etc/systemd/system/$UNIT"
    sed "s#@MOUNTPOINT@#$MNT#g" "$HERE/project-data-status.sh.in" > "$STATUS_SH"
    chmod 0644 "$STATUS_SH"
    say "files installed for $MNT ($MOUNT_UNIT)"

    if ! grep -qF "$HOOK_MARK" "$BASHRC"; then
        cp -p "$BASHRC" "$BASHRC.bak-project-data"
        printf '%s\n%s\n' "$HOOK_MARK" "$HOOK_LINE" >> "$BASHRC"
        say "hook added to $BASHRC (backup: $BASHRC.bak-project-data)"
    fi

    if [[ -n "$USB" ]]; then
        IFS=: read -r vendor product serial <<< "$USB"
        printf '%s\n' "# Keep the data disk awake: USB autosuspend off (installed by host/install.sh --usb)." \
            "ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$vendor\", ATTR{idProduct}==\"$product\", ATTR{serial}==\"$serial\", TEST==\"power/control\", ATTR{power/control}=\"on\"" \
            > "$UDEV_RULE"
        udevadm control --reload
        for d in /sys/bus/usb/devices/*; do
            [ -f "$d/serial" ] && [ "$(cat "$d/idVendor")" = "$vendor" ] && [ "$(cat "$d/idProduct")" = "$product" ] &&
                [ "$(cat "$d/serial")" = "$serial" ] && echo on > "$d/power/control" && say "USB autosuspend off for $d"
        done
    fi

    systemctl daemon-reload
    systemctl enable "$UNIT"
    if systemctl is-active --quiet "$MOUNT_UNIT"; then
        systemctl start "$UNIT"; say "$UNIT started (mount is active)"
    else
        say "$MOUNT_UNIT not active; $UNIT will start with the mount"
    fi
    say "done. Check: systemctl status $UNIT; $STOP_BIN --dry-run"
}

uninstall_all() {
    # Remove the stop helper first so stopping the unit does not stop any containers.
    rm -f "$STOP_BIN"
    systemctl stop "$UNIT" 2>/dev/null || true
    systemctl disable "$UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/$UNIT" "$STATUS_SH" "$UDEV_RULE"
    if grep -qF "$HOOK_MARK" "$BASHRC"; then
        sed -i "\\|^$HOOK_MARK\$|d; \\|^\\[ -r $STATUS_SH \\] && \\. $STATUS_SH\$|d" "$BASHRC"
        say "hook removed from $BASHRC"
    fi
    systemctl daemon-reload
    udevadm control --reload
    say "uninstalled"
}

[[ "$ACTION" == install ]] && install_all || uninstall_all
