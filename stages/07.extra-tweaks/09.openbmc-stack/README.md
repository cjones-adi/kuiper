# Stage 09 — OpenBMC D-Bus → Redfish stack for the ADM1600

This stage installs a from-source OpenBMC stack (bmcweb + phosphor-hwmon +
phosphor-objmgr) onto the Kuiper rootfs and wires it to the ADM1600 (I2C `0x48`,
hwmon) so its sensors appear in Redfish and the web UI.

**End-to-end proof it works:**
```
curl -sk https://<pi>/redfish/v1/Chassis/adm1600/Sensors   # -> 3 Members
```
Web UI: Chassis shows `adm1600` (RackMount, Enabled); Sensors shows
`adm1600 Vin / Iin / Pin`.

---

## The discovery chain (how a sensor becomes a Redfish entry)

```
ADM1600 @ I2C 0x48
  └─ kernel driver -> /sys/class/hwmon/hwmonN/{in1,curr1,power1}_input
       └─ phosphor-hwmon-readd  (unit: xyz.openbmc_project.Hwmon@<of-path>.service)
            owns busname  xyz.openbmc_project.Hwmon-<id>.Hwmon<N>
            publishes     /xyz/openbmc_project/sensors/{voltage,current,power}/adm1600_*
                          each with interface xyz.openbmc_project.Sensor.Value
            └─ phosphor-objmgr / mapperx  (xyz.openbmc_project.ObjectMapper)
                 DISCOVERS every busname by walking org.freedesktop.DBus.Introspectable.Introspect,
                 then indexes objects under /xyz/openbmc_project/sensors
                 └─ adm1600-assoc shim  (xyz.openbmc_project.adm1600.Inventory)
                      publishes the chassis object + an `all_sensors` association
                      (chassis endpoint -> each sensor path)
                      └─ bmcweb  builds /redfish/v1/Chassis/adm1600/Sensors from the association
                           └─ webui-vue  renders the Chassis + Sensors pages
```

**Every link must succeed.** If one is broken the collection silently comes back
empty (`Sensors: []`) — the UI shows the chassis but no device/sensors.

---

## The big gotcha: Debian's D-Bus policy vs. the mapper (SOLVED 2026-09-01)

**Symptom:** everything looked healthy — `i2cdetect` saw 0x48, hwmon inputs
existed, `phosphor-hwmon-readd` ran and owned its busname, the chassis appeared —
but `/redfish/v1/Chassis/adm1600/Sensors` was empty and the dashboard showed no
device.

**Root cause:** Debian's `/usr/share/dbus-1/system.conf` ships a *closed* system
bus: `<deny send_type="method_call"/>` in the default policy, and every service is
expected to "punch holes." OpenBMC normally ships a *wide-open* intra-service bus,
so on Kuiper (Debian base) we have to recreate those holes ourselves in
`files/openbmc-adm1600-dbus.conf`.

The subtle part that cost the most time:

- A per-destination allow (`send_destination="…"`) or even
  `send_destination_prefix="xyz.openbmc_project.Hwmon"` is **not sufficient**.
- `phosphor-objmgr` discovers objects by **walking `Introspect`** on each busname,
  and that walk (like `busctl introspect`/`busctl tree`) addresses the peer by its
  **resolved unique name** (`:1.x`), which `send_destination_prefix` does not
  reliably match. So `GetManagedObjects` (addressed by well-known name) succeeds
  while `Introspect` is denied — the mapper indexes nothing.
- Fix: a **blanket `<allow send_type="method_call"/>`** in both the `root` and
  `default` policies. This mirrors how real OpenBMC ships its bus. Security-
  sensitive system services (systemd1, NetworkManager, login1, …) keep their own
  restrictive `.conf` files, whose denies still override this, so the blast radius
  is limited — and this is a dev bench with bmcweb auth disabled anyway.

**Diagnostic that localizes it** (run on the Pi):
```bash
# owner of the hwmon busname (confirms phosphor-hwmon is up):
busctl status xyz.openbmc_project.Hwmon-adm1600.Hwmon1

# does hwmon actually publish the sensors? (addressed by well-known name -> works
# even under the broken policy):
sudo busctl call xyz.openbmc_project.Hwmon-adm1600.Hwmon1 \
  /xyz/openbmc_project/sensors org.freedesktop.DBus.ObjectManager GetManagedObjects

# the decisive test — Introspect is what the mapper needs; "Access denied" here
# with the above succeeding == the policy gotcha:
sudo busctl introspect xyz.openbmc_project.Hwmon-adm1600.Hwmon1 \
  /xyz/openbmc_project/sensors

# is the mapper indexing the sensors?
sudo busctl call xyz.openbmc_project.ObjectMapper \
  /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper \
  GetSubTreePaths sias /xyz/openbmc_project/sensors 0 1 xyz.openbmc_project.Sensor.Value
```

**Apply / re-apply the fix live (no rebuild):** edit
`/usr/share/dbus-1/system.d/openbmc-adm1600.conf`, then
`sudo systemctl reload dbus && sudo systemctl restart xyz.openbmc_project.ObjectMapper.service`
and restart `adm1600-assoc.service bmcweb.service`.

> Note on `send_destination_prefix`: this build uses **dbus-daemon 1.16.2** (not
> dbus-broker). It *parses* `send_destination_prefix` fine (added in the 1.15.x
> series) — the file was accepted without error — it just doesn't cover the
> unique-name-addressed Introspect walk. That's why we went blanket.

---

## Other failure modes we hit (and where they're fixed)

| Symptom | Cause | Fix (source) |
|---|---|---|
| Web UI login → HTTP 500 for valid creds | bmcweb calls `User.Manager.GetUserInfo` for the Redfish role; we don't run phosphor-user-manager | `adm1600-usermgr` shim (`files/adm1600-usermgr.{cpp,service}`) answers `GetUserInfo` from real Unix groups |
| Login → 401, PAM denies everything | bmcweb `pam_start("webserver",…)` falls back to `/etc/pam.d/other` (deny) | `files/webserver.pam` installed to `/etc/pam.d/webserver` |
| Login rejected for valid `analog`/`analog` on a clean image | `webserver.pam` gates login to the `redfish` group; base Kuiper never creates it or adds `analog` | stage 09 runs `groupadd -f redfish` + `usermod -aG redfish analog` (see below) |
| `/` → 404, no dashboard | pre-built stack ships only bmcweb's own assets, no `index.html` | webui-vue bundle staged at `kuiper-volume/webui/dist`, copied into `/usr/share/www` |
| I2C bus / device absent after boot | `i2c-dev` / `i2c-bcm2835` are modules and never autoloaded | `stage 06/03` writes `/etc/modules-load.d/adm1600-i2c.conf` + `depmod` + `i2c-tools` |
| overlay silently ignored (no `/dev/i2c-1`, no adm1600 hwmon) — even though the lines are in `config.txt` | base Kuiper `config.txt` ends in a `[cm5]` conditional filter; appended lines inherit it and are skipped on a Pi4 | `stage 06/03` prepends an `[all]` filter reset before the ADM1600 lines (see below) |
| bmcweb "not running" after boot | only `bmcweb.socket` enabled (on-demand) | stage 09 enables `bmcweb.service` too (socket still hands it the fd — no port clash) |

### Login credentials & the `redfish` group (fixed in stage 09)
There is **no bmcweb-specific credential** (it is *not* `bmcweb:changeme`). Web UI
login authenticates a **real Unix account** via `pam_unix`. On Kuiper that is the
default **`analog` / `analog`** (root is `root` / `analog`), created in
`stages/03.system-tweaks/01.create-system-users/run.sh`.

But `files/webserver.pam` gates login to members of the **`redfish` group**:
```
auth requisite pam_succeed_if.so user ingroup redfish quiet_success
```
The base Kuiper build never creates that group, and `analog` is only added to
`adm dialout … sudo … i2c` — **not** `redfish`. So on a clean image every web UI
login is rejected *before* authentication completes, even with the right
password. (Note: `analog` being in `sudo` only decides the *role* — priv-admin,
resolved by the usermgr shim **after** PAM — it does **not** satisfy the PAM gate,
which requires `redfish` specifically.)

Stage 09 fixes this in the rootfs:
```bash
groupadd -f redfish
id analog >/dev/null 2>&1 && usermod -aG redfish analog
```
so a clean image logs in out of the box as **`analog` / `analog`** with admin
privilege. To grant another operator web UI access: `sudo usermod -aG redfish <user>`
(takes effect on their next web login — bmcweb re-reads groups each time; no reboot).

To live-fix a Pi that predates this stage change:
`sudo groupadd -f redfish && sudo usermod -aG redfish analog`.

### config.txt gotcha — the `[all]` filter reset (fixed in stage 06/03)
The ADM1600 overlay lives in a *different* stage
(`stages/06.boot-partition/03.adm1600-kernel/run.sh`), but it's easy to lose so
it's recorded here too. Raspberry Pi `config.txt` uses `[…]` **conditional
filter** sections (`[pi4]`, `[cm4]`, `[cm5]`, `[all]`): every line after a filter
applies **only** to matching models until the next filter. The base Kuiper
`config.txt` *ends* inside a `[cm5]` section, so simply appending

```
dtparam=i2c_arm=on
dtoverlay=adm1600
```

makes those lines inherit `[cm5]` and get **silently skipped on a Pi4** — no
`/dev/i2c-1`, no `adm1600` under `/sys/class/hwmon`, and the whole discovery
chain dead at the root, with nothing in the logs to explain it. The fix is to
emit an `[all]` filter reset first:

```
[all]
kernel=kernel8.img
dtparam=i2c_arm=on
dtoverlay=adm1600
```

The stage strips the three keys (`kernel=`, `dtoverlay=adm1600`,
`dtparam=i2c_arm=`) before re-appending, so re-runs stay idempotent, and mirrors
the result into `/boot/firmware/config.txt` when that path exists. If you ever
add more boot-time overlays/params, put them **after** an explicit filter — never
assume the append point is `[all]`.

### Packaging gotcha — the usermgr binary is NOT in the main tarball
`adm1600-usermgr` was built **after** and **separately from**
`openbmc-stack-arm64.tar.zst` (into `kuiper-volume/openbmc/usermgr-stage/`). The
tarball only contains `adm1600-assoc`. Stage 09 therefore installs the usermgr
binary from its stage dir explicitly; if that dir is empty the stage **fails
fast** (rather than shipping an image whose login regresses to 500). Rebuild it
with:
```bash
docker exec obmc-build bash -lc 'cd /work && \
  COMPONENTS="apt sdbusplus usermgr" \
  STAGE=/work/kuiper-volume/openbmc/usermgr-stage bash build-openbmc-arm64.sh'
```

---

## Known-normal cosmetics (not bugs)

- **Chassis fields mostly `--`** (Part/Serial/Model/Manufacturer/Asset tag,
  Power/Min/Max, Health icon). The `adm1600-assoc` shim publishes only the minimum
  (`Item.Board`/`Item.Chassis` + `ChassisType=RackMount` + the `all_sensors`
  association). To populate them, add `Decorator.Asset` / `Decorator.Revision` /
  `OperationalStatus` interfaces to the shim. Optional polish.
- **Sensor values read 0** (`Vin/Iin/Pin = 0`). The sensors are *visible and
  functional*; the zeros are a separate hardware/driver concern (ADM1600 lock
  state / loop not enabled / no live power), not a stack problem.

---

## Sanity checklist after a clean image build

1. `i2cdetect -y 1` shows `48`
2. `systemctl is-active xyz.openbmc_project.ObjectMapper obmc-hwmon-adm1600 adm1600-assoc adm1600-usermgr bmcweb` → all active
3. `curl -sk https://localhost/redfish/v1/Chassis/adm1600/Sensors` → 3 Members
4. Web UI login as **`analog` / `analog`** succeeds (admin); Chassis + Sensors render.
   If login is rejected, confirm the group: `getent group redfish` should list `analog`.
