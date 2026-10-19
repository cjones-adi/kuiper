# 10.lm75-fan — LM75 + PWM-fan "Hello World" (Option K)

A minimal OpenBMC-on-Kuiper thermal demo: an **LM75** temperature sensor and a
**4-pin PWM fan** on a Raspberry Pi 4. As the LM75 warms up, the fan speeds up —
and both the temperature and the fan RPM are visible under Redfish and the
OpenBMC web UI.

## Architecture (Option K — kernel-side control)

```
LM75 (I2C 0x48) ──temp──► Linux thermal zone (step_wise) ──cooling──► PWM fan (GPIO18)
        │                                                                   │
        └── phosphor-hwmon ──► D-Bus ──► bmcweb ──► Redfish / web UI ◄── phosphor-hwmon ──┘
                       (temperature/Ambient)                         (fan_tach/ChassisFan, RPM)
```

- The **control loop runs in the kernel** (DT thermal zone + `step_wise`
  governor). OpenBMC only **observes** — it does not drive the fan.
- `lm75.c` has no thermal code; the **hwmon core** auto-registers its temp
  channel as a DT thermal sensor (`CONFIG_THERMAL_OF=y`), so the overlay can do
  `thermal-sensors = <&lm75 0>`.

## What this provides

Two stages, both **additive** (they do not touch the ADM1600 stages; the demo
coexists with it):

| Stage | Adds |
|---|---|
| `06.boot-partition/04.lm75-fan-overlay` | `lm75-fan.dtbo` (sensor + pwm-fan + thermal zone), `config.txt` lines, module autoload |
| `07.extra-tweaks/10.lm75-fan` (this) | phosphor-hwmon instances for `lm75` + `pwmfan`, `bmc-assoc` drop-in → Chassis `lm75-demo` |

The OpenBMC framework itself (bmcweb, phosphor-objmgr, the `bmc-assoc` binary +
service, usermgr, D-Bus policy, login, webui-vue) comes from
`07/09.openbmc-stack` and is reused unchanged.

## Hardware

- **LM75** on I2C1 at `0x48` (SDA=GPIO2/pin3, SCL=GPIO3/pin5).
- **4-pin PWM fan**: PWM in → **GPIO18** (pin 12); TACH → **GPIO23** (pin 16).
  - TACH is open-collector — **pull up to 3.3 V only** (never 5 V).
  - Fan power (5 V / 12 V) from its own rail, **common ground** with the Pi.

Change the part/address/pins in `../../06.boot-partition/04.lm75-fan-overlay/files/lm75-fan-overlay.dts`.

## Validate after boot

```bash
# Sensors in Redfish (temperature + fan RPM):
curl -k https://<pi-ip>/redfish/v1/Chassis/lm75-demo/Sensors

# Watch "hotter → faster": warm the LM75 and re-read; Ambient and ChassisFan rise.
# Web UI: browse https://<pi-ip>, log in analog/analog, Hardware status → Sensors.

# Threshold (bonus) — read/set the LM75 upper threshold over Redfish:
curl -k https://<pi-ip>/redfish/v1/Chassis/lm75-demo/Sensors/temperature_Ambient
# PATCH Thresholds.UpperCaution.Reading to change the alarm level (alarm only;
# it does NOT change the fan trips, which live in the kernel thermal zone).
```

## Notes

- Fan RPM is visible **only because the fan has a tachometer** — phosphor-hwmon
  publishes `fan_tach` RPM, not PWM duty. A 3-pin (no-tach) fan would still be
  controlled, but the BMC UI would show only the temperature.
- To build a **pure demo image** (no ADM1600), disable the two `*adm1600*`
  stages; this demo depends on `06.03.adm1600-kernel` only for the kernel
  itself (the modules it ships), not for the ADM1600 device.
