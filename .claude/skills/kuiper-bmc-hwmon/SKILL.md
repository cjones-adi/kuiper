---
name: kuiper-bmc-hwmon
description: "Expose a Linux hwmon device (voltage/current/power/temp/fan) in Redfish and the OpenBMC web UI on ADI Kuiper Linux (Debian, arm64, Raspberry Pi 4) by running the real OpenBMC daemons (bmcweb + phosphor-objmgr + phosphor-hwmon) natively — NOT a Yocto obmc-phosphor-image. Use when integrating an I2C/hwmon device (e.g. ADM1600) into the Kuiper BMC framework, adding a device drop-in, or debugging empty Redfish Sensors / web-UI login / D-Bus discovery on Kuiper. Covers the pi-gen stage layout, the prebuilt arm64 stack tarball, the config.txt [all] filter, the first-boot OF-path instantiator, the config-driven bmc-assoc association shim, the Debian D-Bus policy gotcha, and the redfish-group + usermgr login wiring."
---

# hwmon → BMC framework on Kuiper OS

Expose any Linux **hwmon** device under Redfish + the OpenBMC web UI on **ADI
Kuiper Linux** (Debian Trixie, arm64, RPi4) by running the real OpenBMC daemons
on top of Debian. This is **not** a Yocto build — Kuiper is a pi-gen-style
chroot/qemu image builder, and the daemons are pre-compiled into a tarball that a
build stage extracts.

**Proven end-to-end** on RPi4 with the ADM1600 (I2C `0x48`): a clean image build
returns 3 sensors at `https://<pi>/redfish/v1/Chassis/adm1600/Sensors` and logs
in to the web UI as `analog`/`analog`. Everything marked `<device>`/`<addr>`/
`<label>` is what changes for a different part; **adm1600 is the worked example.**

## When to use this skill

- Integrating a new I2C/hwmon device into the Kuiper BMC framework.
- Adding another device to an already-working image (the **drop-in** path).
- Debugging: empty `/redfish/.../Sensors`, chassis-with-no-sensors, web-UI login
  401/500, or "mapper indexes nothing" on Kuiper/Debian.
- Rebuilding or modifying the prebuilt OpenBMC arm64 stack.

## The two-user model (why this is split the way it is)

- **Developer** owns the **kernel side** — driver, device-tree overlay (`.dtbo`),
  and the `config.txt` snippet. Ships these as collateral.
- **ADI/Kuiper image** provides the **framework core** — bmcweb, phosphor-objmgr,
  phosphor-hwmon, the D-Bus policy, and login. Device-agnostic, built once.
- **Per-device user-space glue** — the phosphor-hwmon `LABEL_*` config and the
  association — is now **drop-in data** (`/etc/bmc-assoc/<device>.conf` +
  `<device>-hwmon.conf`), so the developer ships text files and the end-user
  copies them onto a stock image. No recompile.

## The discovery chain (every link must succeed)

```
<device> @ I2C <addr>
  └─ kernel driver -> /sys/class/hwmon/hwmonN/{in1,curr1,power1,...}_input
       └─ phosphor-hwmon-readd  (unit xyz.openbmc_project.Hwmon@<OF-path>.service)
            busname xyz.openbmc_project.Hwmon-<id>.Hwmon<N>
            publishes /xyz/openbmc_project/sensors/{voltage,current,power}/<label>
            └─ phosphor-objmgr / mapperx  (xyz.openbmc_project.ObjectMapper)
                 discovers busnames by walking Introspect, indexes the sensors
                 └─ bmc-assoc shim  (xyz.openbmc_project.BmcAssoc)
                      reads /etc/bmc-assoc/*.conf -> chassis + all_sensors assoc
                      └─ bmcweb -> /redfish/v1/Chassis/<device>/Sensors
                           └─ webui-vue renders Chassis + Sensors
```

If one link breaks the collection silently returns `Sensors: []`. The two links
Debian does **not** give you for free are the **bmc-assoc shim** and the **open
D-Bus policy** the mapper needs to complete discovery.

## The five pieces you add (glue, not daemons)

1. **Kernel/boot** (stage 06) — driver bound + I2C up + overlay + `config.txt`.
2. **phosphor-hwmon config + instantiator** (stage 09) — label channels, start
   the poller at the runtime OF path.
3. **Association shim config** (stage 09) — `/etc/bmc-assoc/<device>.conf`.
4. **D-Bus policy** (stage 09, shared/one-time) — open the Debian bus.
5. **Login** (stage 09, shared/one-time) — PAM + `redfish` group + usermgr shim.

Pieces 1–3 are per-device; 4–5 are shared. See
`references/Kuiper_hwmon_BMC_Integration_Guide.md` for the full narrative and
`references/stage09-runbook.md` for the ADM1600-specific runbook.

## Step 1 — Kernel, I2C, device tree (stage 06)

Reference asset: `assets/stage06-03-adm1600-kernel.run.sh`.

- Strip then re-append boot keys so the stage is idempotent, and **prepend an
  `[all]` filter reset** — the base Kuiper `config.txt` ends in a `[cm5]` section,
  so without `[all]` the overlay is **silently skipped on a Pi4** (no `/dev/i2c-1`,
  no device in `/sys/class/hwmon`, nothing in the logs). This is the #1 silent
  failure. The lines to emit:
  ```
  [all]
  kernel=kernel8.img
  dtparam=i2c_arm=on
  dtoverlay=<device>
  ```
- Autoload I2C: write `/etc/modules-load.d/<device>-i2c.conf` with `i2c-bcm2835`
  and `i2c-dev` (i2c-dev is never autoloaded otherwise), then `depmod` and
  `apt-get install -y i2c-tools`.

## Step 2 — phosphor-hwmon config + first-boot instantiator (stage 09)

phosphor-hwmon's unit is a template `xyz.openbmc_project.Hwmon@%I.service` where
`%I` is the device's **device-tree (OF) path** — known only on the booted Pi. So
ship a config template + a first-boot script that discovers the instance.

- **`assets/adm1600-hwmon.conf`** — set `HW_SENSOR_ID=<device>` and `LABEL_*` for
  the **standard** channels your driver exposes (`inN_`, `currN_`, `powerN_`,
  `tempN_`, `fanN_`). Only these map to phosphor-hwmon sensors; vendor attrs with
  non-standard encodings do not. Units are hwmon-native (mV/mA/µW/m°C).
- **`assets/obmc-hwmon-adm1600-setup.sh`** — finds the hwmon node by `name`,
  derives the OF path from `device/of_node`, reproduces `start_hwmon.sh` escaping
  (`colon="${ofpath//:/--}"`, `esc="$(systemd-escape "$colon")"`), installs the
  conf at `/etc/default/obmc/hwmon/${colon}.conf`, and `systemctl start`s the
  instance. Idempotent.
- **`assets/obmc-hwmon-adm1600.service`** — oneshot, `RemainAfterExit=yes`,
  retries up to 30×1s for the hwmon node, then runs the setup script.

## Step 3 — Association shim: drop-in config, generic binary

**The piece a full OpenBMC image gets from entity-manager.** On Kuiper we ship
one **generic, config-driven** binary that reads `/etc/bmc-assoc/*.conf` and
publishes a chassis + `all_sensors` association per file. Adding a device is a
drop-in `.conf` + `systemctl restart bmc-assoc` — no recompile, no image rebuild.

- **`assets/bmc-assoc.cpp`** — the generic shim. One bus name
  (`xyz.openbmc_project.BmcAssoc`), one `ObjectManager` at
  `/xyz/openbmc_project/inventory`, one chassis object per conf implementing
  `Inventory.Item` (Name, Present) + `Inventory.Item.Board` +
  `Association.Definitions`. Malformed confs are skipped, never fatal. Built by
  the `assoc` component of the stack build.
- **`assets/bmc-assoc.service`** — `Type=dbus`, `ExecStart=/usr/bin/bmc-assoc
  /etc/bmc-assoc`, After/Requires ObjectMapper.
- **`assets/bmc-assoc-adm1600.conf`** — the worked example, installed to
  `/etc/bmc-assoc/adm1600.conf`:
  ```ini
  CHASSIS=adm1600
  NAME=adm1600
  SENSOR=voltage/adm1600_Vin
  SENSOR=current/adm1600_Iin
  SENSOR=power/adm1600_Pin
  ```
  Each `SENSOR` becomes `(all_sensors, chassis, <sensorRoot>/<subpath>)`. The
  subpaths **MUST match** the `LABEL_*` values (hwmon channel → type segment:
  in→voltage, curr→current, power→power, temp→temperature, fan→fan_tach).

> **Self-healing:** phosphor-objmgr defers an association until its endpoint
> exists, so the shim can start before the sensors — it resolves automatically.

## Step 4 — Open the D-Bus policy (shared, one-time)

**The expensive gotcha.** Debian's `/usr/share/dbus-1/system.conf` ships a closed
bus (`<deny send_type="method_call"/>` in the default policy); real OpenBMC ships
an open one. Install **`assets/openbmc-adm1600-dbus.conf`** to
`/usr/share/dbus-1/system.d/`.

A per-destination or `send_destination_prefix` allow is **not enough**:
phosphor-objmgr discovers objects by walking `Introspect`, which addresses peers
by **resolved unique name** (`:1.x`) — so `GetManagedObjects` (well-known name)
succeeds while `Introspect` is denied and the mapper indexes nothing. Fix = a
**blanket `<allow send_type="method_call"/>`** in both `root` and `default`
policies. (dbus-daemon 1.16.2, not dbus-broker.)

## Step 5 — Web UI login (shared, one-time)

Redfish is served **auth-disabled** (`-Dinsecure-disable-auth=enabled`) — `curl`
needs no credentials. The **web UI** does interactive login and needs three
things Debian lacks:

1. **`assets/webserver.pam`** → `/etc/pam.d/webserver`. bmcweb calls
   `pam_start("webserver",…)`; without it PAM falls back to `other`=deny → 401.
   It also **gates login to the `redfish` group**.
2. **`assets/adm1600-usermgr.cpp`** + `.service` — a minimal `User.Manager`
   provider (`GetUserInfo` → priv-admin if in redfish/sudo/priv-admin, else
   priv-user). Without it, valid logins return **HTTP 500**.
3. **Create the group**: `groupadd -f redfish` + `usermod -aG redfish analog`
   (the base Kuiper build never creates it). Then login works out of the box as
   **`analog`/`analog`** (root is `root`/`analog`). There is **no bmcweb
   password** — it authenticates a real Unix account.

## Step 6 — Install + enable (stage 09)

See `assets/stage09-openbmc-stack.run.sh` for the authoritative sequence:
extract the tarball, drop in the glue (Steps 2–5), then:
```bash
systemctl enable xyz.openbmc_project.ObjectMapper.service \
  obmc-hwmon-<device>.service bmc-assoc.service <device>-usermgr.service \
  bmcweb.service bmcweb.socket
```
Enable `bmcweb.service` **and** `bmcweb.socket` (socket alone starts bmcweb only
on first `:443` hit → reads as "not running" after boot; no port clash).

## Building the prebuilt arm64 stack

The daemons are compiled once (emulated build = hours) into
`kuiper-volume/openbmc/openbmc-stack-arm64.tar.zst`. See
`assets/build-openbmc-arm64.sh` (pinned SRCREVs; components
`apt … objmgr hwmon bmcweb assoc usermgr`). The `assoc` component compiles
`bmc-assoc.cpp`; `usermgr` is built **separately** into
`kuiper-volume/openbmc/usermgr-stage/` (stage 09 installs it and **fails fast**
if missing, else login regresses to 500).

```bash
# Full stack + tarball:
docker exec obmc-build bash -lc 'cd /work && RUN_TARBALL=1 bash build-openbmc-arm64.sh'
# Just rebuild the association shim into the tarball:
docker exec obmc-build bash -lc 'cd /work && COMPONENTS="assoc" RUN_TARBALL=1 bash build-openbmc-arm64.sh'
```
On non-arm hosts, `build-docker.sh` re-registers + verifies the `qemu-aarch64`
binfmt handler (lost on WSL2/Docker restart; its absence surfaces ~6 stages later
as "Exec format error").

## Validation (on the booted Pi)

```bash
i2cdetect -y 1                                              # <addr> present
grep -l '^<device>$' /sys/class/hwmon/hwmon*/name          # driver bound
systemctl is-active xyz.openbmc_project.ObjectMapper \
  obmc-hwmon-<device> bmc-assoc <device>-usermgr bmcweb     # all active
# hwmon publishes sensors (works even under a broken bus policy):
sudo busctl call xyz.openbmc_project.Hwmon-<device>.Hwmon1 \
  /xyz/openbmc_project/sensors org.freedesktop.DBus.ObjectManager GetManagedObjects
# mapper indexed them (needs the open D-Bus policy):
sudo busctl call xyz.openbmc_project.ObjectMapper \
  /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper \
  GetSubTreePaths sias /xyz/openbmc_project/sensors 0 1 xyz.openbmc_project.Sensor.Value
curl -sk https://localhost/redfish/v1/Chassis/<device>/Sensors | jq '.Members'
# Web UI: browse https://<pi>, log in analog/analog
```
**Drop-in smoke test (no extra HW):** copy the conf to a new chassis name
pointing at the *same* sensors, `systemctl restart bmc-assoc`, confirm the new
`Chassis/<name>/Sensors` appears, then remove it.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No `/dev/i2c-1`, no device in hwmon | overlay inherited a trailing `[cm5]` filter | `[all]` before overlay lines (Step 1) |
| Sensors in sysfs but `Sensors: []` | mapper's unique-name `Introspect` walk denied | blanket `method_call` policy (Step 4) |
| Chassis shows, no sensors; mapper index empty | missing/mismatched bmc-assoc conf | `SENSOR=` paths must equal `LABEL_*` sensor paths (Step 3) |
| Login → HTTP 500 | no `User.Manager` | usermgr shim built + installed (Step 5) |
| Login → 401 | no `/etc/pam.d/webserver` or user not in `redfish` | PAM + `groupadd redfish` + `usermod -aG` (Step 5) |
| bmcweb "not running" after boot | only `bmcweb.socket` enabled | enable `bmcweb.service` too (Step 6) |

**Decisive D-Bus diagnostic:** if `GetManagedObjects` (by well-known name)
succeeds but `busctl introspect <hwmon-busname> /xyz/openbmc_project/sensors`
returns "Access denied", it's the Step-4 policy gotcha. Live-fix: edit
`/usr/share/dbus-1/system.d/openbmc-adm1600.conf`, `systemctl reload dbus`,
restart ObjectMapper + bmc-assoc + bmcweb.

## Known-normal cosmetics (not bugs)

- **Chassis fields show `--`** — the shim publishes only the minimum interfaces.
  Add `Decorator.Asset`/`Decorator.Revision`/`OperationalStatus` to populate.
- **Sensors read `0`** while visible + `Functional=true` — a device/driver
  concern (lock state, loop not enabled, no live power), not a stack problem.
  Confirm against raw sysfs (`cat $HW/in1_input`).

## Adapting for a new device — checklist

- [ ] Kernel driver present; hwmon `name` = `<device>`; overlay + i2c modules (Step 1).
- [ ] `<device>-hwmon.conf`: `HW_SENSOR_ID` + `LABEL_*` for real channels.
- [ ] `obmc-hwmon-<device>-setup.sh`/`.service`: rename, match the `name` grep.
- [ ] `/etc/bmc-assoc/<device>.conf`: `SENSOR=` paths equal the `LABEL_*` paths.
- [ ] Enable `obmc-hwmon-<device>` + `bmc-assoc` (Step 6).
- [ ] **Reuse unchanged:** the stack tarball, D-Bus policy (Step 4), login (Step 5).

## Assets & references

- `assets/` — the actual working glue files (templates to copy/rename):
  `bmc-assoc.cpp`, `bmc-assoc.service`, `bmc-assoc-adm1600.conf`,
  `adm1600-hwmon.conf`, `obmc-hwmon-adm1600-setup.sh`,
  `obmc-hwmon-adm1600.service`, `adm1600-usermgr.cpp`, `adm1600-usermgr.service`,
  `webserver.pam`, `openbmc-adm1600-dbus.conf`, and the verbatim
  `stage06-03-adm1600-kernel.run.sh`, `stage09-openbmc-stack.run.sh`,
  `build-openbmc-arm64.sh`.
- `references/Kuiper_hwmon_BMC_Integration_Guide.md` — full generic guide.
- `references/stage09-runbook.md` — ADM1600-specific stage 09 runbook + deep
  gotcha analysis (D-Bus, login, config.txt, packaging).
- Live repo: `~/kuiper/stages/06.boot-partition/03.adm1600-kernel/` and
  `~/kuiper/stages/07.extra-tweaks/09.openbmc-stack/`.
