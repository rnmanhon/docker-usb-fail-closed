#!/bin/bash
# ExecStop of project-data-guard.service (installed as /usr/local/sbin/project-data-guard-stop by host/install.sh).
# Stops every running container with a bind-mount source at or under $PROJECT_DATA_MOUNT,
# then tells logged-in users with wall (skipped during shutdown).
#
#   project-data-guard-stop             stop matching containers (needs docker access)
#   project-data-guard-stop --dry-run   only list matching containers
#
# Every docker call is time-bounded and failures are tolerated: this runs while the disk
# or the Docker daemon may already be gone, and must never block the unmount.
set -u

MNT=${PROJECT_DATA_MOUNT:-/mnt/project-data}
MNT=${MNT%/}
DOCKER_TIMEOUT=10   # seconds for docker ps / inspect
STOP_GRACE=20       # docker stop -t
STOP_TIMEOUT=100    # whole docker stop call; keep below the unit's TimeoutStopSec
RUNBOOK="check the filesystem (e2fsck), mount it, then recreate the affected stacks"

dry_run=0
[ "${1:-}" = "--dry-run" ] && dry_run=1

log() { echo "project-data-guard: $*" >&2; }

# Print the names of running containers using $MNT, one per line.
find_users() {
    command -v docker >/dev/null 2>&1 || { log "docker not installed"; return 0; }
    local ids
    if ! ids=$(timeout "$DOCKER_TIMEOUT" docker ps -q 2>/dev/null); then
        log "docker ps failed or timed out; cannot stop containers"
        return 0
    fi
    [ -n "$ids" ] || return 0
    # shellcheck disable=SC2086  # word-splitting the id list is intended
    timeout "$DOCKER_TIMEOUT" docker inspect \
        --format '{{.Name}}{{range .Mounts}}{{"\t"}}{{.Source}}{{end}}' $ids 2>/dev/null |
    while IFS=$'\t' read -r -a fields; do
        local name=${fields[0]#/} src
        for src in "${fields[@]:1}"; do
            if [ "$src" = "$MNT" ] || [[ $src == "$MNT"/* ]]; then
                echo "$name"
                break
            fi
        done
    done
}

mapfile -t users < <(find_users)

if [ "$dry_run" -eq 1 ]; then
    [ "${#users[@]}" -eq 0 ] || printf '%s\n' "${users[@]}"
    exit 0
fi

stopped="none"
if [ "${#users[@]}" -gt 0 ]; then
    log "stopping: ${users[*]}"
    if timeout "$STOP_TIMEOUT" docker stop -t "$STOP_GRACE" "${users[@]}" >/dev/null; then
        stopped="${users[*]}"
    else
        log "docker stop failed or timed out for some of: ${users[*]}"
        stopped="${users[*]} (some may still be running: check docker ps)"
    fi
else
    log "no running containers use $MNT"
fi

# Why did the mount go away? Device still present = deliberate unmount.
fs_spec=$(awk -v m="$MNT" '$1 !~ /^#/ && $2 == m { print $1; exit }' /etc/fstab 2>/dev/null)
uuid=${fs_spec#UUID=}
if [ "$(systemctl is-system-running 2>/dev/null)" = "stopping" ]; then
    log "system shutdown; no wall message"
    exit 0
elif [ "$uuid" != "$fs_spec" ] && [ -n "$uuid" ] && [ ! -e "/dev/disk/by-uuid/$uuid" ]; then
    reason="the disk DISCONNECTED"
else
    reason="it was unmounted"
fi
log "$MNT offline: $reason"

printf '%s\n' \
    "project-data: $MNT is offline ($reason)." \
    "Stopped containers: $stopped" \
    "Nothing restarts automatically. Recovery: $RUNBOOK" |
    timeout 5 wall 2>/dev/null || true
exit 0
