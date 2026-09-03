# Adding a hwmon Device to the BMC Framework on Kuiper OS

> **Date:** September 1, 2026\
> **Applies to:** ADI Kuiper Linux (Debian Trixie, arm64) on Raspberry Pi 4\
> **Purpose:** Expose any Linux **hwmon** device (voltage/current/power/temp/fan)
> in Redfish and the OpenBMC web UI, using the real OpenBMC daemons running
> **natively on Kuiper** — not a Yocto `obmc-phosphor-image`.\
> **Worked example:** ADM1600 hot-swap controller (I2C `0x48`). Everything marked
> `<device>` / `<addr>` / `<label>` is what you change for a different part.

---

## How this differs from the Yocto guide

If you've read `docs/devices/adm1600/ADM1600_phosphor_hwmon_Guide.md`, that guide
targets a **Yocto/BitBake** build (`local.conf`, `.bbappend` recipes,
`bitbake obmc-phosphor-image`, flashing a `.wic`). **This guide does not use any
of that.** Kuiper is a Debian image built by a **pi-gen-style chroot/qemu image
builder**, and we run the *same* OpenBMC daemons on top of Debian.

| Concern | Yocto OpenBMC | **Kuiper (this guide)** |
|---|---|---|
| Build system | BitBake recipes, `local.conf` | pi-gen **stages** (`stages/**/run.sh`) |
| Getting the daemons | compiled by the image | **prebuilt arm64 tarball** extracted by a stage |
| I2C enable | `ENABLE_I2C = "1"` | `config.txt` (`dtparam=i2c_arm=on` + overlay) |
| Sensor→chassis link | entity-manager auto-discovery | **hand-written association shim** (no entity-manager) |
| D-Bus bus policy | wide-open intra-service bus (shipped) | **Debian closes it — you must open it** |
| Web UI login | phosphor-user-manager + PAM | **usermgr shim + `redfish` group + PAM** |
| Deploy | flash `.wic` | `build-docker.sh` → flash `.img` |

The single most important consequence: **on Debian you must recreate three things
that a real OpenBMC image gives you for free** — the sensor↔chassis association,
an open D-Bus policy, and a `User.Manager` for login. The rest is standard
phosphor-hwmon.

---

## The discovery chain (how a sysfs value becomes a Redfish sensor)

```
<device> @ I2C <addr>
  └─ kernel driver -> /sys/class/hwmon/hwmonN/{in1,curr1,power1,tempN,...}_input
       └─ phosphor-hwmon-readd   (unit: xyz.openbmc_project.Hwmon@<OF-path>.service)
            owns busname  xyz.openbmc_project.Hwmon-<id>.Hwmon<N>
            publishes     /xyz/openbmc_project/sensors/{voltage,current,power}/<label>
                          each implementing xyz.openbmc_project.Sensor.Value
            └─ phosphor-objmgr / mapperx   (xyz.openbmc_project.ObjectMapper)
                 DISCOVERS every busname by walking
                 org.freedesktop.DBus.Introspectable.Introspect,
                 then indexes objects under /xyz/openbmc_project/sensors
                 └─ <device>-assoc shim   (publishes chassis + `all_sensors` assoc)
                      chassis object + Association.Definitions(all_sensors -> sensors)
                      └─ bmcweb   builds /redfish/v1/Chassis/<device>/Sensors
                           └─ webui-vue   renders the Chassis + Sensors pages
```

**Every link must succeed.** If one is broken the collection silently returns
`Sensors: []` — the UI shows the chassis but no sensors. The two links that do
**not** exist by default on Debian are the **assoc shim** and (implicitly) the
**open D-Bus policy** that lets the mapper complete its discovery walk.

---

## Prerequisites

### 1. The prebuilt OpenBMC stack (device-agnostic — build once)

The daemons (`bmcweb`, `phosphor-objmgr`, `phosphor-hwmon`) are compiled once for
arm64/Trixie and packaged into a tarball that a Kuiper stage extracts. This stack
is **not per-device** — you build it once and reuse it for every hwmon device.

```bash
# On the host, in a persistent arm64 build container (see ~/kuiper/build-openbmc-arm64.sh):
docker exec obmc-build bash -lc 'cd /work && RUN_TARBALL=1 bash build-openbmc-arm64.sh'
# -> writes kuiper-volume/openbmc/openbmc-stack-arm64.tar.zst
```

> `kuiper-volume/` is bind-mounted at `/kuiper-volume` inside the Kuiper build
> container and is **gitignored** (it holds large artifacts). The stage fails
> fast if the tarball is missing.

### 2. A kernel with your driver + I2C

Your device's hwmon driver must be present in the Kuiper kernel and the I2C bus
must be enabled at boot. For the ADM1600 this is handled by stage
`06.boot-partition/03.adm1600-kernel` (see Step 1).

---

## What you add per device (five pieces)

For each new hwmon device you add **glue**, not daemons:

1. **Kernel/boot** — driver bound + I2C bus up + device-tree overlay (stage 06).
2. **phosphor-hwmon config + instantiator** — label the channels and start the
   poller for your device's runtime OF path (stage 09).
3. **Association shim** — publish a chassis object + `all_sensors` association so
   bmcweb has a `Chassis/<device>/Sensors` to populate (stage 09).
4. **D-Bus policy** — one shared open policy so the mapper can discover objects
   (stage 09; shared across all devices — you usually don't touch it again).
5. **(Optional) Web UI login** — PAM + `redfish` group + usermgr shim (stage 09;
   also shared — set up once).

Pieces 4 and 5 are **one-time, shared** setup. Pieces 1–3 are per-device.

---

## Step 1 — Kernel, I2C, and device tree (stage 06)

Reference: `stages/06.boot-partition/03.adm1600-kernel/run.sh`.

### 1a. Enable I2C and load your overlay in `config.txt`

```bash
CFG="${BUILD_DIR}/boot/config.txt"
sed -i '/^kernel=/d;/^dtoverlay=<device>/d;/^dtparam=i2c_arm=/d' "${CFG}"
cat >> "${CFG}" <<'EOF'

# --- <device> BMC kernel + sensor overlay ---
# [all] resets any preceding conditional filter. The base Kuiper config.txt ends
# in a [cm5] section; WITHOUT [all] these lines inherit that filter and are
# silently skipped on a Pi4 -> no /dev/i2c-1 and no <device> in /sys/class/hwmon.
[all]
kernel=kernel8.img
dtparam=i2c_arm=on
dtoverlay=<device>
EOF
```

> **The `[all]` filter reset is the #1 silent failure on Kuiper.** Raspberry Pi
> `config.txt` uses `[pi4]`/`[cm4]`/`[cm5]`/`[all]` conditional sections; every
> line after a filter applies only to matching models. Because the base file ends
> inside `[cm5]`, appending your overlay without `[all]` first makes it apply only
> to a CM5 — on a Pi4 it's ignored with nothing in the logs.

### 1b. Autoload the I2C modules + install i2c-tools

`i2c-dev` and `i2c-bcm2835` are built as modules and `i2c-dev` is never
autoloaded, so nothing opens `/dev/i2c-*` without this:

```bash
install -Dm644 /dev/stdin "${BUILD_DIR}/etc/modules-load.d/<device>-i2c.conf" <<'EOF'
i2c-bcm2835
i2c-dev
EOF
chroot "${BUILD_DIR}" depmod "${KREL}"
chroot "${BUILD_DIR}" apt-get install -y --no-install-recommends i2c-tools
```

---

## Step 2 — phosphor-hwmon config + runtime instantiator (stage 09)

phosphor-hwmon's unit is a **template**, `xyz.openbmc_project.Hwmon@%I.service`,
where `%I` is the device's **device-tree (OF) path** — which is only known on the
booted Pi. So we ship a config **template** plus a **first-boot script** that
discovers the instance and drops the config at the `%I`-derived path.

### 2a. The config template

`files/<device>-hwmon.conf` — label only the **standard** hwmon channels your
driver exposes (`inN_`, `currN_`, `powerN_`, `tempN_`, `fanN_`):

```ini
# D-Bus busname suffix: xyz.openbmc_project.Hwmon-<device>.Hwmon1
HW_SENSOR_ID=<device>

# Sensor labels -> D-Bus /xyz/openbmc_project/sensors/<type>/<label>
LABEL_in1=<device>_Vin
LABEL_curr1=<device>_Iin
LABEL_power1=<device>_Pin

# Optional thresholds (hwmon units: mV / mA / µW / m°C):
# WARNHI_in1 = 14000
# CRITHI_in1 = 15000
```

> **Units matter:** phosphor-hwmon reads hwmon's native units (voltage **mV**,
> current **mA**, power **µW**, temp **m°C**) and publishes SI on D-Bus (V, A, W,
> °C). Thresholds in the conf are in **hwmon** units.

> **Only standard channels are phosphor-hwmon-native.** Vendor attributes with
> non-standard encodings (e.g. ADM1600's IEEE-754 `pid*`, `duty_cycle`) are **not
> hwmon sensors** and need a separate custom D-Bus service — out of scope here.

### 2b. The first-boot instantiator

`files/obmc-hwmon-<device>-setup.sh` finds the hwmon node by `name`, derives its
OF path, reproduces phosphor-hwmon's `start_hwmon.sh` escaping so the config
filename matches `%I`, installs the config, and starts the poller. Idempotent:

```bash
#!/bin/bash
set -euo pipefail
TEMPLATE=/usr/share/<device>/<device>-hwmon.conf
CONFROOT=/etc/default/obmc/hwmon

# 1. Locate the hwmon class device by its driver 'name'
hwmon=""
for d in /sys/class/hwmon/hwmon*; do
	[ -r "$d/name" ] || continue
	if [ "$(cat "$d/name")" = "<device>" ]; then hwmon="$d"; break; fi
done
[ -n "$hwmon" ] || { echo "ERROR: <device> hwmon not found (driver bound? overlay loaded?)" >&2; exit 1; }

# 2. Derive the OF (device-tree) path backing the device
ofnode="$hwmon/device/of_node"
if [ -e "$ofnode" ]; then
	full="$(readlink -f "$ofnode")"                 # .../devicetree/base/soc/.../<device>@<addr>
	ofpath="${full#/sys/firmware/devicetree/base}"  # /soc/.../<device>@<addr>
else
	dp="$(readlink -f "$hwmon/device")"; ofpath="${dp#/sys}"
fi

# 3. Reproduce start_hwmon.sh escaping to match the unit + %I conf path
colon="${ofpath//:/--}"           # == systemd %I (unescaped instance)
esc="$(systemd-escape "$colon")"  # == the @<instance> token in the unit name

# 4. Install the conf at the %I path and 5. start the poller
conf="${CONFROOT}${colon}.conf"
install -d "$(dirname "$conf")"; install -m644 "$TEMPLATE" "$conf"
systemctl start "xyz.openbmc_project.Hwmon@${esc}.service"
```

### 2c. The oneshot service that runs it

`files/obmc-hwmon-<device>.service` — waits for the hwmon node to appear (the
I2C device may enumerate slightly after boot), then runs the setup script:

```ini
[Unit]
Description=Configure and start phosphor-hwmon for the <device>
After=xyz.openbmc_project.ObjectMapper.service
Wants=xyz.openbmc_project.ObjectMapper.service
ConditionPathExists=/sys/class/hwmon

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do grep -qx <device> /sys/class/hwmon/hwmon*/name 2>/dev/null && exit 0; sleep 1; done; exit 0'
ExecStart=/usr/bin/obmc-hwmon-<device>-setup.sh

[Install]
WantedBy=multi-user.target
```

---

## Step 3 — The association / inventory shim (stage 09)

**This is the piece a real OpenBMC image gives you via entity-manager, and the
usual reason `Sensors` is empty.** phosphor-hwmon publishes `Sensor.Value`
objects, but bmcweb builds `Chassis/<device>/Sensors` from an **association**
(`all_sensors`) hanging off a **chassis inventory object**. No chassis + no
association ⇒ empty collection.

Write a tiny sdbusplus service (`files/<device>-assoc.cpp`) that publishes one
inventory object plus the association. The sensor paths must match your
`LABEL_*` exactly:

```cpp
constexpr const char* busName = "xyz.openbmc_project.<device>.Inventory";
const std::string chassisPath =
    "/xyz/openbmc_project/inventory/system/chassis/<device>";
constexpr const char* sensorRoot = "/xyz/openbmc_project/sensors";

// (forward, reverse, endpoint): chassis --all_sensors--> each sensor path.
// phosphor-objmgr synthesises the reverse (<sensor>/chassis) automatically.
const std::vector<Association> associations = {
    {"all_sensors", "chassis", std::string(sensorRoot) + "/voltage/<device>_Vin"},
    {"all_sensors", "chassis", std::string(sensorRoot) + "/current/<device>_Iin"},
    {"all_sensors", "chassis", std::string(sensorRoot) + "/power/<device>_Pin"},
};
// ... request_name, then:
server.add_manager("/xyz/openbmc_project/inventory");   // emit InterfacesAdded
// chassisPath implements: Inventory.Item (Name, Present),
//                         Inventory.Item.Board (matches bmcweb chassisInterfaces),
//                         Association.Definitions (Associations = a(sss))
```

Its unit (`files/<device>-assoc.service`) must start **after** the ObjectMapper:

```ini
[Unit]
Requires=xyz.openbmc_project.ObjectMapper.service
After=xyz.openbmc_project.ObjectMapper.service
Wants=obmc-hwmon-<device>.service
After=obmc-hwmon-<device>.service
[Service]
Type=dbus
BusName=xyz.openbmc_project.<device>.Inventory
ExecStart=/usr/bin/<device>-assoc
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
```

> **Self-healing gotcha:** phosphor-objmgr **defers** an association until its
> endpoint object exists on D-Bus. If the shim starts before the sensors are
> published, the association is created **later**, automatically, once
> phosphor-hwmon publishes them. That's expected — don't "fix" it with ordering
> hacks beyond the `Wants=`/`After=` above.

> The chassis object publishes only the **minimum** interfaces, so the web UI's
> Chassis card shows `--` for Part/Serial/Model/etc. That's **cosmetic**
> (see [Known-normal cosmetics](#known-normal-cosmetics)).

---

## Step 4 — Open the D-Bus policy (shared, one-time)

**The subtle, expensive gotcha.** Debian's `/usr/share/dbus-1/system.conf` ships
a **closed** system bus (`<deny send_type="method_call"/>` in the default
policy); services are expected to punch holes. Real OpenBMC ships a **wide-open**
intra-service bus. On Kuiper you must recreate that.

Install `files/openbmc-<device>-dbus.conf` (shared across all your OpenBMC
services — you write it once) to
`/usr/share/dbus-1/system.d/openbmc-<device>.conf`:

```xml
<busconfig>
  <policy user="root">
    <allow own_prefix="xyz.openbmc_project"/>
    <allow send_type="method_call"/>
    <allow receive_sender="xyz.openbmc_project.ObjectMapper"/>
  </policy>
  <policy context="default">
    <allow send_type="method_call"/>
    <allow receive_sender="xyz.openbmc_project.ObjectMapper"/>
    <allow receive_sender="xyz.openbmc_project.User.Manager"/>
  </policy>
</busconfig>
```

**Why a per-destination allow is NOT enough** (this is the part that costs
people hours): phosphor-objmgr discovers objects by **walking
`org.freedesktop.DBus.Introspectable.Introspect`** on every busname, and that
walk (like `busctl introspect`/`busctl tree`) addresses the peer by its
**resolved unique name** (`:1.x`) — which `send_destination_prefix` does **not**
reliably match. So `GetManagedObjects` (addressed by well-known name) succeeds
while `Introspect` returns "Access denied", the mapper indexes nothing, and
`Sensors` is empty. The **blanket `<allow send_type="method_call"/>`** is what
covers the discovery walk.

> Blast radius: security-sensitive system services (systemd1, NetworkManager,
> login1, …) keep their own restrictive `.conf` files whose denies still override
> this. This is a dev bench with bmcweb auth disabled, so the open bus is
> acceptable. (Env here: `dbus-daemon 1.16.2`, not dbus-broker.)

---

## Step 5 — Web UI login (shared, one-time)

Redfish is served **auth-disabled** on this bench
(`-Dinsecure-disable-auth=enabled`), so `curl` needs no credentials. The
**web UI**, however, does interactive login, which needs two things Debian
doesn't provide:

1. **A PAM policy** at `/etc/pam.d/webserver` (bmcweb calls
   `pam_start("webserver", …)`; without it PAM falls back to `other` = deny →
   every login 401). It also **gates login to the `redfish` group**:

   ```
   auth      requisite  pam_succeed_if.so user ingroup redfish quiet_success
   auth      required   pam_unix.so
   account   required   pam_unix.so
   ```

2. **A `User.Manager` provider.** After PAM succeeds, bmcweb calls
   `xyz.openbmc_project.User.Manager.GetUserInfo` for the Redfish role. Real
   OpenBMC runs phosphor-user-manager; we don't, so a **usermgr shim**
   (`files/<device>-usermgr.cpp`, owning only that name) answers it from the
   user's **Unix groups** (`redfish`/`sudo`/`priv-admin` → `priv-admin`, else
   `priv-user`). Without it, valid logins return **HTTP 500**.

3. **Create the `redfish` group** and add the default user (the base Kuiper build
   never creates it):

   ```bash
   chroot "${BUILD_DIR}" /bin/bash -e <<'EOF'
   groupadd -f redfish
   id analog >/dev/null 2>&1 && usermod -aG redfish analog
   EOF
   ```

> **There is no bmcweb password.** Login uses a **real Unix account** — on Kuiper
> the default is **`analog` / `analog`** (root is `root` / `analog`). Add more
> operators with `sudo usermod -aG redfish <user>`.

> **Packaging trap:** the usermgr binary is built **separately** from the main
> stack tarball (into `kuiper-volume/openbmc/usermgr-stage/`), so stage 09 installs
> it explicitly and **fails fast** if missing — otherwise a clean image enables
> the service with no binary and login regresses to 500.

---

## Step 6 — Enable the services (stage 09)

```bash
chroot "${BUILD_DIR}" systemctl enable \
	xyz.openbmc_project.ObjectMapper.service \
	obmc-hwmon-<device>.service \
	<device>-assoc.service \
	<device>-usermgr.service \
	bmcweb.service \
	bmcweb.socket
```

> Enable `bmcweb.service` **and** `bmcweb.socket`: the socket alone starts bmcweb
> only on the first `:443` connection (reads as "not running" after boot).
> Enabling the service starts it at boot; systemd still hands it the socket fd, so
> there's no port clash.

---

## Build and deploy

```bash
cd ~/kuiper
sudo ./build-docker.sh          # ~2 hours: full ADI suite compiles under qemu
# -> kuiper-volume/image_<date>-ADI-Kuiper-Linux-arm64.img (+ .zip)

# Flash (replace sdX):
sudo dd if=kuiper-volume/image_<date>-ADI-Kuiper-Linux-arm64.img \
	of=/dev/sdX bs=4M status=progress conv=fsync && sync
```

> On a non-arm host, `build-docker.sh` (re-)registers and **verifies** the
> `qemu-aarch64` binfmt handler — it does not survive a WSL2/Docker restart, and
> its absence surfaces ~6 stages later as a confusing "Exec format error".

---

## Validation (on the booted Pi)

```bash
# 1. Bus + device
i2cdetect -y 1                                   # <addr> present (e.g. 48)

# 2. hwmon sysfs
grep -l '^<device>$' /sys/class/hwmon/hwmon*/name
HW=$(dirname "$(grep -l '^<device>$' /sys/class/hwmon/hwmon*/name)")
cat "$HW"/in1_input "$HW"/curr1_input "$HW"/power1_input   # mV / mA / µW

# 3. Services all active
systemctl is-active xyz.openbmc_project.ObjectMapper \
  obmc-hwmon-<device> <device>-assoc <device>-usermgr bmcweb

# 4. phosphor-hwmon publishes the sensors (works even under a broken bus policy)
sudo busctl call xyz.openbmc_project.Hwmon-<device>.Hwmon1 \
  /xyz/openbmc_project/sensors org.freedesktop.DBus.ObjectManager GetManagedObjects

# 5. The mapper indexed them (this needs the open D-Bus policy from Step 4)
sudo busctl call xyz.openbmc_project.ObjectMapper \
  /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper \
  GetSubTreePaths sias /xyz/openbmc_project/sensors 0 1 xyz.openbmc_project.Sensor.Value

# 6. Redfish (auth-disabled — no credentials needed)
curl -sk https://localhost/redfish/v1/Chassis/<device>/Sensors | jq '.Members'

# 7. Web UI: browse https://<pi>  and log in with  analog / analog
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No `/dev/i2c-1`, no `<device>` in `/sys/class/hwmon` | overlay inherited the base file's trailing `[cm5]` filter | add `[all]` before the overlay lines (Step 1a) |
| `i2cdetect` missing / bus absent | `i2c-dev`/`i2c-bcm2835` not autoloaded | `modules-load.d` + `depmod` (Step 1b) |
| Sensors in sysfs but **`Sensors: []`** in Redfish | mapper can't complete its unique-name `Introspect` walk | blanket `method_call` D-Bus policy (Step 4) |
| Chassis shows, but no sensors, and mapper index (validation #5) is empty | missing association shim, or `LABEL_*` ≠ shim sensor paths | Step 3; make paths match exactly |
| Web UI login → **HTTP 500** for valid creds | no `User.Manager` for the role lookup | usermgr shim built + installed (Step 5) |
| Web UI login → **401**, PAM denies all | no `/etc/pam.d/webserver`, or user not in `redfish` | install PAM policy + `groupadd redfish` + `usermod -aG` (Step 5) |
| bmcweb "not running" after boot | only `bmcweb.socket` enabled | enable `bmcweb.service` too (Step 6) |

**The decisive D-Bus diagnostic** (run on the Pi) — distinguishes the policy bug
from a phosphor-hwmon problem:

```bash
# SUCCEEDS (addressed by well-known name):
sudo busctl call xyz.openbmc_project.Hwmon-<device>.Hwmon1 \
  /xyz/openbmc_project/sensors org.freedesktop.DBus.ObjectManager GetManagedObjects
# "Access denied" here while the above succeeds == the Step-4 policy gotcha:
sudo busctl introspect xyz.openbmc_project.Hwmon-<device>.Hwmon1 \
  /xyz/openbmc_project/sensors
```

**Apply the policy fix live (no rebuild):** edit
`/usr/share/dbus-1/system.d/openbmc-<device>.conf` →
`sudo systemctl reload dbus` →
`sudo systemctl restart xyz.openbmc_project.ObjectMapper.service` →
restart `<device>-assoc.service bmcweb.service`.

---

## Known-normal cosmetics (not bugs)

- **Chassis fields show `--`** (Part/Serial/Model/Manufacturer/Asset, Power
  min/max, health icon). The assoc shim publishes only the minimum interfaces.
  To populate them, add `Decorator.Asset` / `Decorator.Revision` /
  `OperationalStatus` interfaces to the shim. Optional polish.
- **Sensor values read `0`** while the sensors are visible and `Functional=true`.
  That's a **device/driver** concern (e.g. the part's lock state, a control loop
  not enabled, or no live power) — **not** a stack problem. Confirm against raw
  sysfs (`cat $HW/in1_input`): if sysfs is also 0, it's hardware/driver.

---

## Adapting this guide for YOUR device — checklist

Change these, everything else is reused:

- [ ] **Kernel driver** present and bound; hwmon `name` = `<device>`.
- [ ] **Overlay** `dtoverlay=<device>` (and `<device>-i2c.conf`, `depmod`).
- [ ] **`<device>-hwmon.conf`**: `HW_SENSOR_ID` + `LABEL_*` for the channels your
      driver actually exposes (check `ls /sys/class/hwmon/hwmonN/`). Add temp/fan
      labels (`LABEL_temp1`, `LABEL_fan1`) if present.
- [ ] **`obmc-hwmon-<device>-setup.sh`** + **`.service`**: rename, match the
      `name` grep.
- [ ] **`<device>-assoc.cpp`**: busname, chassis path, and the association
      **endpoint paths must equal** `/xyz/openbmc_project/sensors/<type>/<label>`
      for every `LABEL_*` above.
- [ ] **Enable** the new `obmc-hwmon-<device>` + `<device>-assoc` units (Step 6).
- [ ] **Reuse unchanged:** the prebuilt stack tarball, the D-Bus policy (Step 4),
      and the login setup (Step 5) — these are shared across devices.

> Multiple devices: give each its own hwmon conf + assoc shim (distinct busname,
> chassis path, and labels). The stack, D-Bus policy, and login are shared.

---

## References

- **Kuiper stage (authoritative):** `~/kuiper/stages/07.extra-tweaks/09.openbmc-stack/`
  (`run.sh`, `files/`, and its `README.md` runbook).
- **Kernel/boot stage:** `~/kuiper/stages/06.boot-partition/03.adm1600-kernel/run.sh`.
- **Architecture plan:** `Kuiper_Phosphor_Bmcweb_Architecture_Plan.md` (this dir).
- **Yocto counterpart:** `docs/devices/adm1600/ADM1600_phosphor_hwmon_Guide.md`.
- phosphor-hwmon: https://github.com/openbmc/phosphor-hwmon
- OpenBMC sensor architecture: https://github.com/openbmc/docs/blob/master/architecture/sensor-architecture.md
- hwmon kernel docs: https://www.kernel.org/doc/html/latest/hwmon/

---

**Document Version:** 1.0\
**Last Updated:** September 1, 2026\
**Status:** Validated end-to-end on RPi4 (ADM1600, clean image build)
