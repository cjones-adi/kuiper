# Adding a hwmon Device to the BMC Framework on Kuiper OS

> **Date:** September 3, 2026\
> **Applies to:** ADI Kuiper Linux (Debian Trixie, arm64) on Raspberry Pi 4\
> **Purpose:** Expose any Linux **hwmon** device (voltage/current/power/temp/fan)
> in Redfish and the OpenBMC web UI, using the real OpenBMC daemons running
> **natively on Kuiper** — not a Yocto `obmc-phosphor-image`.\
> **Worked example:** ADM1600 hot-swap controller (I2C `0x48`). Everything marked
> `<device>` / `<addr>` / `<label>` is what you change for a different part.

---

## Who this is for: two users, one framework

This integration is built around **two distinct roles**. Keeping them separate is
the key to understanding *what lives where* — and why most of the work is
**one-time** rather than per-device.

| | **Platform / driver developer** | **End-user (device buyer)** |
|---|---|---|
| Owns | the kernel side + the device package | the running system |
| Produces | builtin **driver**, **`.dtbo`**, `config.txt` lines, a small **drop-in package** | nothing — *consumes* the above |
| Ships to the other | kernel image + `.dtbo` + drop-in files + a short "apply this" note | — |
| Does | writes/validates the driver once | downloads the stock **Kuiper image with BMC-framework support**, applies the developer's package, reboots |
| Gets in return | — | Redfish + a web UI for the device, **instead of** a bespoke `pyadi-iio` script or custom page |

The thing that makes this tractable: **the BMC framework itself is
device-agnostic and shipped once, inside the Kuiper image.** Adding a device does
**not** rebuild the framework — it drops a few text files onto a running system.

### What the framework gives you (baked into the image, built once)

These are compiled/configured a single time by the platform team and never mention
any specific device:

- `bmcweb` — the Redfish + web server
- `phosphor-objmgr` / mapperx — the D-Bus object index
- `phosphor-hwmon` — the sysfs→D-Bus sensor poller (template unit + `readd`)
- **`bmc-assoc`** — the **generic, config-driven** inventory/association shim
  (reads `/etc/bmc-assoc/*.conf` at startup — see Step 3)
- the **open D-Bus policy** (Debian ships a closed bus; the framework opens it)
- the **login stack** — PAM `webserver` policy, a `User.Manager` shim, the
  `redfish` group

### What the developer ships per device (the drop-in package)

Small, device-specific, **copied onto a stock framework image** — no image rebuild:

1. **Kernel image** (driver builtin) **+ `.dtbo`** + the `config.txt` lines.
2. **hwmon labeling** — a `<device>-hwmon.conf` plus a tiny instantiator (Step 2).
3. **Association drop-in** — one `/etc/bmc-assoc/<device>.conf` (Step 3).

### Kernel space vs. user space — and how it maps onto the two users

> **Kernel space makes the device *appear* as hwmon; user space turns that hwmon
> node into a Redfish sensor.** That boundary is exactly the developer/end-user
> boundary.

- **Kernel space (developer's builtin driver + `.dtbo`)** binds the part and
  exposes `/sys/class/hwmon/hwmonN/{in1,curr1,power1,…}_input`. This is the
  developer's domain and is delivered as a kernel image + overlay.
- **User space (the framework + the drop-in confs)** reads those sysfs files and
  publishes them on D-Bus, indexes them, associates them to a chassis, and serves
  them over Redfish. The device-agnostic half is baked into the image; the
  per-device half is the developer's drop-in package.

So "device configuration for the BMC framework" is **user-space configuration** —
text files consumed by daemons already present in the image — layered on top of a
**kernel-space** driver the developer supplies.

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
| Sensor→chassis link | entity-manager auto-discovery | **config-driven `bmc-assoc` shim** (no entity-manager) |
| D-Bus bus policy | wide-open intra-service bus (shipped) | **Debian closes it — you must open it** |
| Web UI login | phosphor-user-manager + PAM | **usermgr shim + `redfish` group + PAM** |
| Deploy | flash `.wic` | `build-docker.sh` → flash `.img` |

The single most important consequence: **on Debian you must recreate three things
that a real OpenBMC image gives you for free** — the sensor↔chassis association,
an open D-Bus policy, and a `User.Manager` for login. All three are in the
framework image; the rest is standard phosphor-hwmon.

---

## The discovery chain (how a sysfs value becomes a Redfish sensor)

```
<device> @ I2C <addr>                                    [ kernel space — developer ]
  └─ kernel driver -> /sys/class/hwmon/hwmonN/{in1,curr1,power1,tempN,...}_input
       └─ phosphor-hwmon-readd   (unit: xyz.openbmc_project.Hwmon@<OF-path>.service)   [ user space — framework + drop-in ]
            owns busname  xyz.openbmc_project.Hwmon-<id>.Hwmon<N>
            publishes     /xyz/openbmc_project/sensors/{voltage,current,power}/<label>
                          each implementing xyz.openbmc_project.Sensor.Value
            └─ phosphor-objmgr / mapperx   (xyz.openbmc_project.ObjectMapper)
                 DISCOVERS every busname by walking
                 org.freedesktop.DBus.Introspectable.Introspect,
                 then indexes objects under /xyz/openbmc_project/sensors
                 └─ bmc-assoc   (xyz.openbmc_project.BmcAssoc)
                      reads /etc/bmc-assoc/*.conf and publishes, per file,
                      a chassis object + `all_sensors` association -> the sensors
                      └─ bmcweb   builds /redfish/v1/Chassis/<device>/Sensors
                           └─ webui-vue   renders the Chassis + Sensors pages
```

**Every link must succeed.** If one is broken the collection silently returns
`Sensors: []` — the UI shows the chassis but no sensors. The two links that do
**not** exist by default on Debian are the **association** (now provided by the
generic `bmc-assoc` reading your drop-in conf) and the **open D-Bus policy** that
lets the mapper complete its discovery walk. Both are in the framework image.

---

## Building the framework image (platform team — one-time)

*Skip this whole section if you already have a Kuiper image with BMC-framework
support — as an end-user adding a device, you do.* This is how the reusable,
device-agnostic image is produced.

### The prebuilt OpenBMC stack (device-agnostic)

The daemons (`bmcweb`, `phosphor-objmgr`, `phosphor-hwmon`) **and the generic
`bmc-assoc` shim** are compiled once for arm64/Trixie and packaged into a tarball
that a Kuiper stage extracts. This stack is **not per-device**.

```bash
# On the host, in a persistent arm64 build container (see ~/kuiper/build-openbmc-arm64.sh):
docker exec obmc-build bash -lc 'cd /work && RUN_TARBALL=1 bash build-openbmc-arm64.sh'
# -> writes kuiper-volume/openbmc/openbmc-stack-arm64.tar.zst
```

> `kuiper-volume/` is bind-mounted at `/kuiper-volume` inside the Kuiper build
> container and is **gitignored** (it holds large artifacts). The stage fails
> fast if the tarball is missing.
>
> **`qemu-aarch64` binfmt does not survive a WSL2/Docker restart.** If a build
> exec dies with "Exec format error", re-register it with
> `docker run --rm --privileged multiarch/qemu-user-static --reset -p yes`.
> `build-docker.sh` verifies this for the image build; the standalone
> `docker exec` above does not.

The framework stage (`stages/07.extra-tweaks/09.openbmc-stack`) installs the
device-agnostic pieces: the stack, the generic `bmc-assoc` **binary + service**,
the **open D-Bus policy** (Step 4), and the **login stack** (Step 5). It enables
them so on boot: `dbus → ObjectMapper → hwmon poller → bmc-assoc → bmcweb(:443)`.

> **Bench note:** for the single-device bench, this same stage also bakes in the
> ADM1600 *example* drop-in files (its hwmon conf, instantiator, and
> `bmc-assoc-adm1600.conf`). On a truly device-agnostic image those would be
> omitted, and the ADM1600 files delivered as the developer's package below. The
> mechanism is identical either way — the only question is whether the files are
> pre-copied or dropped in at runtime.

---

## Adding your device (developer package + end-user drop-in)

Everything below is the **per-device** work. On a stock framework image these are
files you **drop in at runtime** — no rebuild. Pieces 4–5 (D-Bus policy, login)
are already in the image and are **not** repeated per device.

### Step 1 — Kernel, I2C, and device tree

Reference: `stages/06.boot-partition/03.adm1600-kernel/run.sh`.

The **developer** delivers a kernel image with the driver builtin, a `.dtbo`, and
the `config.txt` lines. The **end-user** installs them and reboots.

#### 1a. Enable I2C and load the overlay in `config.txt`

```bash
CFG=/boot/config.txt        # (image build: "${BUILD_DIR}/boot/config.txt")
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

#### 1b. Autoload the I2C modules + install i2c-tools

`i2c-dev` and `i2c-bcm2835` are built as modules and `i2c-dev` is never
autoloaded, so nothing opens `/dev/i2c-*` without this:

```bash
install -Dm644 /dev/stdin /etc/modules-load.d/<device>-i2c.conf <<'EOF'
i2c-bcm2835
i2c-dev
EOF
depmod "$(uname -r)"          # image build: chroot ... depmod "${KREL}"
apt-get install -y --no-install-recommends i2c-tools
```

### Step 2 — phosphor-hwmon config + instantiator (per-device drop-in)

phosphor-hwmon's unit is a **template**, `xyz.openbmc_project.Hwmon@%I.service`,
where `%I` is the device's **device-tree (OF) path** — only known on the booted
Pi. So the developer ships a config **template** plus a **first-boot script** that
discovers the instance and drops the config at the `%I`-derived path. These are
part of the drop-in package.

> **Scope note:** unlike the association (Step 3, one generic reader), the hwmon
> instantiator is still **per-device** today — the script greps for your `name`
> and points at your template. Generalizing it into a single config-driven reader
> (à la `bmc-assoc`) is the natural next step; until then, ship these two small
> files with the package.

#### 2a. The config template

`<device>-hwmon.conf` — label only the **standard** hwmon channels your driver
exposes (`inN_`, `currN_`, `powerN_`, `tempN_`, `fanN_`). On the running system it
is consumed at `/usr/share/<device>/<device>-hwmon.conf`:

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

#### 2b. The first-boot instantiator

`obmc-hwmon-<device>-setup.sh` finds the hwmon node by `name`, derives its OF
path, reproduces phosphor-hwmon's `start_hwmon.sh` escaping so the config filename
matches `%I`, installs the config, and starts the poller. Idempotent:

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

#### 2c. The oneshot service that runs it

`obmc-hwmon-<device>.service` — waits for the hwmon node to appear (the I2C device
may enumerate slightly after boot), then runs the setup script:

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

### Step 3 — The association: a drop-in `.conf` (no recompile)

**This is the piece a real OpenBMC image gives you via entity-manager, and the
usual reason `Sensors` is empty.** phosphor-hwmon publishes `Sensor.Value`
objects, but bmcweb builds `Chassis/<device>/Sensors` from an **association**
(`all_sensors`) hanging off a **chassis inventory object**. No chassis + no
association ⇒ empty collection.

**You no longer write or compile any C++ for this.** The framework image ships a
single generic daemon, **`bmc-assoc`** (busname `xyz.openbmc_project.BmcAssoc`),
that reads **every** `/etc/bmc-assoc/*.conf` at startup and publishes, per file,
one chassis object plus its `all_sensors` association. Adding a device is a
**drop-in**: write one small conf and restart the service.

#### 3a. Write the device conf

`/etc/bmc-assoc/<device>.conf` — the `SENSOR` paths must match your `LABEL_*`
exactly (`<type>/<label>`, relative to `/xyz/openbmc_project/sensors`):

```ini
CHASSIS=<device>
NAME=<device>
SENSOR=voltage/<device>_Vin
SENSOR=current/<device>_Iin
SENSOR=power/<device>_Pin
```

| Key | Meaning |
|---|---|
| `CHASSIS` | **required** — becomes `/redfish/v1/Chassis/<CHASSIS>` |
| `NAME` | optional display name (defaults to `CHASSIS`) |
| `SENSOR` | **repeatable** — a sensor subpath (or an absolute D-Bus path) |
| `SENSOR_ROOT` | optional — override the default `/xyz/openbmc_project/sensors` |

`LABEL_` → sensor **type** mapping (hwmon channel → D-Bus subtree): `in` →
`voltage`, `curr` → `current`, `power` → `power`, `temp` → `temperature`, `fan` →
`fan_tach`.

#### 3b. Apply it (this is the whole "recompile" — a service restart)

```bash
sudo cp <device>.conf /etc/bmc-assoc/<device>.conf
sudo systemctl restart bmc-assoc
curl -sk https://localhost/redfish/v1/Chassis            # -> now lists <device>
curl -sk https://localhost/redfish/v1/Chassis/<device>/Sensors   # -> your sensors
```

That's the payoff of the config-driven model: **a new device needs a text file
and a service restart — no arm64 recompile, no tarball repack, no image reflash.**
A malformed conf is skipped (not fatal), so one bad file can't take down the
others.

> **Self-healing gotcha:** phosphor-objmgr **defers** an association until its
> endpoint object exists on D-Bus. If `bmc-assoc` starts before the sensors are
> published, the association is created **later**, automatically, once
> phosphor-hwmon publishes them. The chassis appears immediately; its
> `all_sensors` resolves once the hwmon poller is up. That's expected — don't
> "fix" it with ordering hacks.

> The chassis object publishes only the **minimum** interfaces, so the web UI's
> Chassis card shows `--` for Part/Serial/Model/etc. That's **cosmetic**
> (see [Known-normal cosmetics](#known-normal-cosmetics)).

### Step 4 — Open the D-Bus policy (in the framework image — reference only)

*Already in the image; you do not repeat this per device. Included so you
understand the chain and can live-patch a bench.*

**The subtle, expensive gotcha.** Debian's `/usr/share/dbus-1/system.conf` ships
a **closed** system bus (`<deny send_type="method_call"/>` in the default
policy); services are expected to punch holes. Real OpenBMC ships a **wide-open**
intra-service bus. The framework recreates that in
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

### Step 5 — Web UI login (in the framework image — reference only)

*Already in the image; set up once, shared by all devices.*

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
   (owning only that name) answers it from the user's **Unix groups**
   (`redfish`/`sudo`/`priv-admin` → `priv-admin`, else `priv-user`). Without it,
   valid logins return **HTTP 500**.

3. **The `redfish` group** exists and the default user is a member (the base
   Kuiper build never creates it):

   ```bash
   groupadd -f redfish
   id analog >/dev/null 2>&1 && usermod -aG redfish analog
   ```

> **There is no bmcweb password.** Login uses a **real Unix account** — on Kuiper
> the default is **`analog` / `analog`** (root is `root` / `analog`). Add more
> operators with `sudo usermod -aG redfish <user>`.

> **Packaging trap (framework build):** the usermgr binary is built **separately**
> from the main stack tarball (into `kuiper-volume/openbmc/usermgr-stage/`), so the
> stage installs it explicitly and **fails fast** if missing — otherwise a clean
> image enables the service with no binary and login regresses to 500.

### Step 6 — Enable the per-device services

The framework services (`ObjectMapper`, `bmc-assoc`, `bmcweb`, usermgr) are
already enabled in the image. Per device you only add the **hwmon instantiator**;
`bmc-assoc` just needs a restart to pick up your new conf:

```bash
# runtime drop-in on a stock image:
sudo systemctl enable --now obmc-hwmon-<device>.service
sudo systemctl restart bmc-assoc.service
```

At image-build time the stage enables the full set once:

```bash
chroot "${BUILD_DIR}" systemctl enable \
	xyz.openbmc_project.ObjectMapper.service \
	obmc-hwmon-<device>.service \
	bmc-assoc.service \
	<device>-usermgr.service \
	bmcweb.service \
	bmcweb.socket
```

> Enable `bmcweb.service` **and** `bmcweb.socket`: the socket alone starts bmcweb
> only on the first `:443` connection (reads as "not running" after boot).
> Enabling the service starts it at boot; systemd still hands it the socket fd, so
> there's no port clash.

---

## The end-user drop-in, end to end (no rebuild)

Given a stock **Kuiper image with BMC-framework support** and the developer's
package, the end-user's entire procedure is:

```bash
# 1. Kernel side (developer's kernel image + .dtbo + config.txt note) -> reboot
sudo cp <device>.dtbo /boot/overlays/
#    ...apply the developer's config.txt lines (Step 1a), then:  sudo reboot

# 2. hwmon labeling (from the package)
sudo install -Dm644 <device>-hwmon.conf        /usr/share/<device>/<device>-hwmon.conf
sudo install -Dm755 obmc-hwmon-<device>-setup.sh /usr/bin/obmc-hwmon-<device>-setup.sh
sudo install -Dm644 obmc-hwmon-<device>.service  /usr/lib/systemd/system/obmc-hwmon-<device>.service

# 3. Association drop-in (from the package)
sudo install -Dm644 <device>.conf              /etc/bmc-assoc/<device>.conf

# 4. Start it
sudo systemctl daemon-reload
sudo systemctl enable --now obmc-hwmon-<device>.service
sudo systemctl restart bmc-assoc.service

# 5. Verify
curl -sk https://localhost/redfish/v1/Chassis/<device>/Sensors | jq '.Members'
#    ...and browse https://<pi>  (login analog / analog)
```

No `build-docker.sh`, no reflash. The framework was built once; the device is
just files.

---

## Build and deploy the framework image (platform team)

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
  obmc-hwmon-<device> bmc-assoc <device>-usermgr bmcweb

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

**Prove the drop-in model** (what the config-driven `bmc-assoc` buys you): add a
throwaway chassis with only a file + restart, then remove it.

```bash
printf 'CHASSIS=testdev\nNAME=testdev\nSENSOR=voltage/<device>_Vin\n' \
  | sudo tee /etc/bmc-assoc/test.conf >/dev/null
sudo systemctl restart bmc-assoc
curl -sk https://localhost/redfish/v1/Chassis            # -> lists <device> AND testdev
sudo rm /etc/bmc-assoc/test.conf && sudo systemctl restart bmc-assoc
curl -sk https://localhost/redfish/v1/Chassis            # -> back to just <device>
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No `/dev/i2c-1`, no `<device>` in `/sys/class/hwmon` | overlay inherited the base file's trailing `[cm5]` filter | add `[all]` before the overlay lines (Step 1a) |
| `i2cdetect` missing / bus absent | `i2c-dev`/`i2c-bcm2835` not autoloaded | `modules-load.d` + `depmod` (Step 1b) |
| Sensors in sysfs but **`Sensors: []`** in Redfish | mapper can't complete its unique-name `Introspect` walk | blanket `method_call` D-Bus policy (Step 4) |
| Chassis shows, but no sensors, and mapper index (validation #5) is empty | `bmc-assoc` conf missing, or `SENSOR=` paths ≠ `LABEL_*` sensor paths | Step 3; make paths match exactly, then `systemctl restart bmc-assoc` |
| A device's chassis never appears | its `/etc/bmc-assoc/<device>.conf` is malformed (skipped) or `CHASSIS=` missing | check `journalctl -u bmc-assoc`; fix the conf, restart |
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
restart `bmc-assoc.service bmcweb.service`.

---

## Known-normal cosmetics (not bugs)

- **Chassis fields show `--`** (Part/Serial/Model/Manufacturer/Asset, Power
  min/max, health icon). `bmc-assoc` publishes only the minimum interfaces.
  To populate them, extend the shim with `Decorator.Asset` / `Decorator.Revision`
  / `OperationalStatus` interfaces (and, ideally, matching conf keys). Optional
  polish.
- **Sensor values read `0`** while the sensors are visible and `Functional=true`.
  That's a **device/driver** concern (e.g. the part's lock state, a control loop
  not enabled, or no live power) — **not** a stack problem. Confirm against raw
  sysfs (`cat $HW/in1_input`): if sysfs is also 0, it's hardware/driver.

---

## Adapting this guide for YOUR device — checklist

**Reused unchanged (in the framework image):** the prebuilt stack tarball, the
generic `bmc-assoc` binary + service, the D-Bus policy (Step 4), and the login
stack (Step 5). You never rebuild these to add a device.

**Per device (the drop-in package):**

- [ ] **Kernel driver** present and bound; hwmon `name` = `<device>`.
- [ ] **Overlay** `dtoverlay=<device>` (and `<device>-i2c.conf`, `depmod`).
- [ ] **`<device>-hwmon.conf`**: `HW_SENSOR_ID` + `LABEL_*` for the channels your
      driver actually exposes (check `ls /sys/class/hwmon/hwmonN/`). Add temp/fan
      labels (`LABEL_temp1`, `LABEL_fan1`) if present.
- [ ] **`obmc-hwmon-<device>-setup.sh`** + **`.service`**: rename, match the
      `name` grep.
- [ ] **`/etc/bmc-assoc/<device>.conf`**: `CHASSIS` + one `SENSOR=` per
      `LABEL_*`, using `<type>/<label>` that **equals**
      `/xyz/openbmc_project/sensors/<type>/<label>`. **No C++, no recompile.**
- [ ] **Apply:** `systemctl enable --now obmc-hwmon-<device>` +
      `systemctl restart bmc-assoc` (or enable both at image-build time).

> **Multiple devices:** each gets its own hwmon conf + instantiator and its own
> `/etc/bmc-assoc/<device>.conf`. The stack, `bmc-assoc` binary, D-Bus policy, and
> login are shared. `bmc-assoc` publishes one chassis per conf file.

---

## References

- **Kuiper stage (authoritative):** `~/kuiper/stages/07.extra-tweaks/09.openbmc-stack/`
  (`run.sh`, `files/`, and its `README.md` runbook).
- **Kernel/boot stage:** `~/kuiper/stages/06.boot-partition/03.adm1600-kernel/run.sh`.
- **Recreate-it-all skill:** `~/kuiper/.claude/skills/kuiper-bmc-hwmon/` — the
  self-contained skill (SKILL.md + verbatim assets + references) an AI can follow
  to rebuild this whole stack end-to-end.
- **Architecture plan:** `Kuiper_Phosphor_Bmcweb_Architecture_Plan.md` (this dir).
- **Yocto counterpart:** `docs/devices/adm1600/ADM1600_phosphor_hwmon_Guide.md`.
- phosphor-hwmon: https://github.com/openbmc/phosphor-hwmon
- OpenBMC sensor architecture: https://github.com/openbmc/docs/blob/master/architecture/sensor-architecture.md
- hwmon kernel docs: https://www.kernel.org/doc/html/latest/hwmon/

---

**Document Version:** 2.0\
**Last Updated:** September 3, 2026\
**Status:** Validated end-to-end on RPi4 (ADM1600, clean image build); config-driven
`bmc-assoc` drop-in verified live (chassis added/removed via a `.conf` + service restart)
