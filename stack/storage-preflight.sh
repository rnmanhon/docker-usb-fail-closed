#!/bin/bash
# Storage preflight for a Docker Compose stack that keeps data on a separately mounted disk.
#
#   storage-preflight.sh -m /mnt/project-data [-m /mnt/other] [-- COMPOSE OPTIONS...]
#
# Run it before `docker compose up` (e.g. as ExecStartPre= of the stack's systemd unit, see
# 10-required-mounts.conf.example), from the project directory, with the same Compose options
# (-f files, --profile ...) and environment (COMPOSE_PROFILES, .env) the stack starts with.
# Exits 0 when it is safe to start, 78 (EX_CONFIG) otherwise; never starts anything itself.
#
# Checks, for each -m mountpoint that an active service actually binds (others are skipped):
#   - it has a UUID= entry in /etc/fstab (that UUID is "the right disk");
#   - it is mounted, from the device that UUID points to (a wrong disk is rejected);
#   - it is mounted read/write (ext4 errors=remount-ro shows up here);
#   - every bind source of the resolved Compose project on it (also through a symlink) exists
#     (it is never created), really lives on that filesystem, and is writable unless bound :ro.
# Warns when such a bind uses short syntax (Docker would create a missing folder) or when the
# service's restart policy is not "no" (the Docker daemon could start it without this check).
#
# Reads only /etc/fstab, /proc/self/mountinfo, /dev/disk/by-uuid links and the bind sources'
# metadata. Needs docker compose and python3. Test overrides: FSTAB, MOUNTINFO, DEV_BY_UUID.
set -uo pipefail

EXIT_FAIL=78
FSTAB="${FSTAB:-/etc/fstab}"
MOUNTINFO="${MOUNTINFO:-/proc/self/mountinfo}"
DEV_BY_UUID="${DEV_BY_UUID:-/dev/disk/by-uuid}"

mounts=() compose_opts=()
while (( $# )); do
    case "$1" in
        -m) mounts+=("${2%/}"); shift 2 ;;
        --) shift; compose_opts=("$@"); break ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "usage: $0 -m MOUNTPOINT [-m ...] [-- COMPOSE OPTIONS]" >&2; exit 2 ;;
    esac
done
(( ${#mounts[@]} )) || { echo "usage: $0 -m MOUNTPOINT [-m ...] [-- COMPOSE OPTIONS]" >&2; exit 2; }

say() { echo "storage preflight: $*" >&2; }

fstab_uuid() { # mountpoint -> UUID from its active fstab entry (empty if none / not UUID=)
    awk -v m="$1" '$1 !~ /^#/ && $2 == m { print $1; exit }' "$FSTAB" 2>/dev/null | sed -n 's/^UUID=//p'
}
mountinfo_entry() { # mountpoint -> "<source> <per-mount opts>,<superblock opts>" of the topmost mount
    awk -v m="$1" '$5 == m { for (i = 7; i <= NF; i++) if ($i == "-") break
        e = $(i + 2) " " $6 "," $(i + 3) } END { if (e != "") print e }' "$MOUNTINFO" 2>/dev/null
}
mount_of() { # absolute path -> longest mountpoint containing it
    awk -v p="$1" '{ m = $5; if ((p == m || index(p, (m == "/" ? "/" : m "/")) == 1) && length(m) > length(best)) best = m }
        END { print best }' "$MOUNTINFO"
}
on_mount() { # source mountpoint -> true if source is the mountpoint or under it, also via symlinks
    local real; real="$(readlink -m -- "$1" 2>/dev/null || true)"
    [[ "$1" == "$2" || "$1" == "$2"/* || "$real" == "$2" || "$real" == "$2"/* ]]
}

for m in "${mounts[@]}"; do
    [[ "$m" == /?* ]] || { say "FAIL $m: mountpoints must be absolute and not /"; exit $EXIT_FAIL; }
done

# Bind mounts of the resolved project: service, source, read_only, create_host_path, restart.
if ! binds="$(docker compose "${compose_opts[@]}" config --format json | python3 -I -c '
import json, sys
for name, svc in (json.load(sys.stdin).get("services") or {}).items():
    for v in svc.get("volumes") or []:
        if v.get("type") != "bind": continue
        chp = (v.get("bind") or {}).get("create_host_path", True)
        print("\t".join([name, v.get("source", ""), str(bool(v.get("read_only"))).lower(),
                         str(chp).lower(), svc.get("restart") or "no"]))')"; then
    say "FAIL cannot resolve the Compose configuration to check bind mounts"; exit $EXIT_FAIL
fi

used=()
for m in "${mounts[@]}"; do
    while IFS=$'\t' read -r service source _; do
        if [[ -n "$service" ]] && on_mount "$source" "$m"; then used+=("$m"); break; fi
    done <<< "$binds"
    [[ " ${used[*]} " == *" $m "* ]] || say "skipped $m: no active service binds it"
done
(( ${#used[@]} )) || exit 0

fail=0
for m in "${used[@]}"; do
    uuid="$(fstab_uuid "$m")"
    [[ -n "$uuid" ]] || { say "FAIL $m: no UUID= entry in $FSTAB, so the expected disk is unknown"; fail=1; continue; }
    entry="$(mountinfo_entry "$m")"
    [[ -n "$entry" ]] || { say "FAIL $m: not mounted (disk UUID $uuid missing or not mounted yet)"; fail=1; continue; }
    src="${entry%% *}"; opts="${entry#* }"
    expected="$(readlink -f "$DEV_BY_UUID/$uuid" 2>/dev/null || true)"
    if [[ ! -e "$DEV_BY_UUID/$uuid" || "$src" != "$expected" ]]; then
        say "FAIL $m: mounted from $src, but fstab expects UUID $uuid${expected:+ ($expected)}: wrong disk"; fail=1; continue
    fi
    [[ ",$opts," != *,ro,* ]] || { say "FAIL $m: mounted read-only (filesystem error?)"; fail=1; continue; }
done
(( fail == 0 )) || exit $EXIT_FAIL

while IFS=$'\t' read -r service source ro chp restart; do
    [[ -n "$service" ]] || continue
    for m in "${used[@]}"; do
        on_mount "$source" "$m" || continue
        if [[ ! -e "$source" ]]; then
            say "FAIL $service: $source does not exist (create it on the mounted disk; it is never created automatically)"
            fail=1; break
        fi
        real="$(readlink -f "$source")"; on="$(mount_of "$real")"
        [[ "$on" == "$m" ]] || { say "FAIL $service: $source resolves to $real on ${on:-?}, not on $m"; fail=1; break; }
        [[ "$ro" == true || -w "$source" ]] || { say "FAIL $service: $source is not writable by $(id -un)"; fail=1; break; }
        [[ "$chp" == false ]] || say "warning $service: bind $source should use long syntax with bind.create_host_path: false"
        [[ "$restart" == no ]] || say "warning $service: restart: $restart lets the Docker daemon start it without this check; use restart: \"no\""
        break
    done
done <<< "$binds"
(( fail == 0 )) || exit $EXIT_FAIL
say "ok: ${used[*]}"
