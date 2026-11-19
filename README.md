# docker-usb-fail-closed

Run Docker Compose services with part of their data on a removable (USB) disk, and make them **fail
closed** when that disk disappears: stop the containers that use it, never write to the wrong disk,
tell a human, and wait for someone to check the disk. Linux with systemd (tested on Ubuntu 24.04,
systemd 255, Docker Engine 29 with Compose v2).

Companion code for the article *Fail-Closed Storage for Docker: Running Production Services on a
Removable USB Disk*.

## What goes wrong by default

- With the short bind syntax, Docker **creates a missing bind source**. Disk not mounted: the app
  starts with an empty folder on your system disk and writes there.
- `restart: unless-stopped` lets the Docker daemon **start containers at boot** around any check you
  put in a systemd unit.
- A disk that vanishes while running only produces I/O errors in the app's log. **Nobody is told.**

## Layers

| # | Layer | Where |
|---|---|---|
| 1 | ext4 (not exFAT), mounted by UUID with `nofail`, a short device timeout, `x-systemd.device-bound`, `errors=remount-ro` | [examples/fstab.example](examples/fstab.example) |
| 2 | `chattr +i` on the empty mountpoint: nothing can be created there while the disk is absent | [examples/fstab.example](examples/fstab.example) |
| 3 | Compose long bind syntax with `create_host_path: false`; `restart: "no"` for services on the disk | [stack/compose.example.yml](stack/compose.example.yml) |
| 4 | Stack unit drop-in: `RequiresMountsFor`, `BindsTo`/`After` the mount unit, preflight, `RestartPreventExitStatus=78` | [stack/10-required-mounts.conf.example](stack/10-required-mounts.conf.example) |
| 5 | Preflight: right disk (fstab UUID), read/write, every bind source present and really on the disk | [stack/storage-preflight.sh](stack/storage-preflight.sh) |
| 6 | Catch-all guard: stops **any** container with a bind source on the disk when the mount stops (dev stacks, `docker run`) | [host/](host/) |
| 6b | Docker ordered after the mount (drop-in, ordering only): `unless-stopped` containers find their data at boot, and at shutdown Docker stops them itself before the unmount, so they come back after a reboot | `host/10-docker-after-mount.conf.in` |
| 7 | Tell a human: `wall` on loss, red warning in every new shell (also non-login shells) | [host/](host/) |
| 8 | Optional: USB autosuspend off for this one disk | `host/install.sh --usb` |
| 9 | Check before `docker compose up --force-recreate` in your helper scripts (it is not all-or-nothing) | [tools/dc-storage-check](tools/dc-storage-check) |

## Install

1. **Disk.** Format ext4 (`mkfs.ext4 -m 0 -L project-data /dev/sdX1` — check the device first), add the
   fstab line from [examples/fstab.example](examples/fstab.example) with its UUID, `chattr +i` the empty
   mountpoint, then mount it through systemd.
2. **Host guard** (stop helper, guard unit, shell warning, optional udev rule):
   ```bash
   sudo ./host/install.sh --mount /mnt/project-data [--usb VENDOR:PRODUCT:SERIAL]
   systemctl status project-data-guard.service
   /usr/local/sbin/project-data-guard-stop --dry-run   # lists containers it would stop
   ```
   `--uninstall` removes everything it installed.
3. **Each stack** whose data moves to the disk:
   - Compose: long bind syntax with `create_host_path: false`, data path from a per-machine variable,
     `restart: "no"` ([stack/compose.example.yml](stack/compose.example.yml)).
   - `sudo install -m 0755 stack/storage-preflight.sh /usr/local/bin/`
   - Drop-in for the stack's systemd unit ([stack/10-required-mounts.conf.example](stack/10-required-mounts.conf.example)),
     then `sudo systemctl daemon-reload`.
   - Try it without starting anything: `storage-preflight.sh -m /mnt/project-data -- -f compose.yml`.
4. **Helper scripts** that run `docker compose up`: call `tools/dc-storage-check` with the same options first.

Machines without the disk need none of this, and the same Compose files keep working there: the data path
falls back to its default, and `dc-storage-check` is a no-op when no fstab mount is involved.

## Moving a service's data

1. While it runs: `rsync -aHAX --numeric-ids OLD/ /mnt/project-data/…/NEW/`, and time a final `sync` too
   (rsync finishes while data may still be in RAM; SMR disks are slow on long writes).
2. Stop the stack, run the same rsync again with `--delete` (only on the verified destination).
3. Compare file counts, bytes and owners. For a checksum against the disk rather than RAM, drop the copied
   files from the page cache first (`posix_fadvise(..., POSIX_FADV_DONTNEED)`), then `rsync -anc`.
4. Switch the settings (data path, `restart: "no"`), install the drop-in, start the stack through the preflight.
5. Check the bind source (`docker inspect`), restart policies, old data readable, new data on the disk.
6. Delete the old copy.

## Test it (on an empty disk first)

- Soft: `sudo systemctl stop 'mnt-project\x2ddata.mount'` with a throwaway container writing to the disk.
  Expect the container stopped, a `wall` message ("unmounted"), a red warning in new shells, and nothing
  creatable under the bare mountpoint.
- Real: pull the cable. Expect the mount unit to stop by itself, the guard to stop the container before the
  unmount, `wall` saying "disk DISCONNECTED", and no automatic mount when the cable comes back.
- Boot without the disk: the host boots; the stack's unit fails its dependency; no container on the disk is
  started by Docker.

## Recover

```bash
sudo e2fsck -p /dev/disk/by-uuid/<UUID>          # "recovering journal ... clean" is normal after a pull
sudo systemctl start 'mnt-project\x2ddata.mount'
sudo systemctl start my-stack.service            # recreates containers: fresh bind mounts
```

Never `docker start` a container that was running during the loss: it still points at the dead mount.

## Limits

- Pulling the cable still loses in-flight writes. These layers limit the damage, they do not prevent it.
- A disk that turns read-only or returns I/O errors without disappearing does not stop a running stack;
  the next start is refused.
- With `restart: "no"`, a crashed container stays down until the stack is restarted.
- Raw `docker compose up` bypasses the preflight. `create_host_path: false` and the immutable mountpoint
  still prevent writes to the wrong disk.
- A bind of a parent such as `/mnt` is not matched by the guard; do not bind parents of the mountpoint.
- Keep data you read whole and often (for example ML models in use) on the internal disk: a USB hard disk
  reads at ~100 MB/s.

## Files

```
host/install.sh                       install/uninstall the host guard (--mount, --usb)
host/project-data-guard.service.in    guard unit template
host/project-data-guard-stop.sh       stops containers with a bind source on the disk; wall
host/project-data-status.sh.in        new-shell warning template
host/10-docker-after-mount.conf.in    docker.service ordering drop-in template
stack/storage-preflight.sh            preflight for a stack (exit 78 on failure)
stack/10-required-mounts.conf.example drop-in for the stack's systemd unit
stack/compose.example.yml             bind and restart settings
tools/dc-storage-check                check for helper scripts before compose up
examples/fstab.example                fstab line, chattr +i
```

## License

MIT, see [LICENSE](LICENSE). The scripts run as root and change systemd, udev and shell startup files: read them, and try them on a test machine or an empty disk first.
