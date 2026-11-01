# SMC keys

These keys were found on a **MacBook Pro 14" M5 Max (Mac17,7), macOS 27.2**, which exposes 3,866 SMC keys. Other Macs differ — that's why [hardware reports](../.github/ISSUE_TEMPLATE/hardware_report.yml) are so valuable. You can list the keys on your own Mac with `smcfan keys` (all) or `smcfan keys F` (fans only).

Key names are four characters. Below, `0` and `1` are the fan index and `*` means "any character".

## Fans

| Key | Type | Meaning | Example |
|---|---|---|---|
| `FNum` | ui8 | number of fans | 2 |
| `F0Ac` | flt | actual speed (rpm) | 2315 |
| `F0Tg` | flt | target speed (rpm) — written in manual mode | 2317 |
| `F0Mn` | flt | minimum speed (rpm) | 2317 |
| `F0Mx` | flt | maximum speed (rpm) | 7826 |
| `F0md` | ui8 | mode: 0 = automatic (macOS), 1 = manual | 0 |
| `F0St` | ui8 | fan status | 5 |
| `F0Dc` | flt | duty cycle (fraction) | 0.09 |

On M1–M4 Macs the mode key is reported as `F0Md` (capital M), and some models only accept manual mode after `Ftst` (force test) is set to 1. The M5 Max has no `Ftst` key.

When macOS decides the Mac is cool enough, it stops the fans: `F0Ac` reads 0.

## Temperatures

All temperatures are `flt` in °C. SMC Fan uses the CPU and GPU groups; the others are listed for reference. Readings outside 10–130 °C are ignored.

| Prefix | Count | What it seems to measure | Used by SMC Fan |
|---|---|---|---|
| `Tp**` | 23 | CPU cores (performance and efficiency clusters) | ✅ CPU |
| `Tg**` | 84 | GPU | ✅ GPU |
| `Tm**` | ~40 | memory / SoC fabric | |
| `Ts**` | ~15 | SoC | |
| `Te**`, `Tf**` | — | various; `Tf06`/`Tf16` read ~96 °C at idle and are clearly not die temperatures | |
| `TB*T` | 3 | battery | |
| `TC**`, `TH**`, `TN**`, `TV**`, `TW**`, `Ta**` | — | chargers, SSD, NAND, VRMs, wireless, ambient | |

## Power

| Key | Type | Meaning | Example (idle on a 90 W adapter) |
|---|---|---|---|
| `PSTR` | flt | total system power (W) | 19.3 |
| `PDTR` | flt | power coming in from the adapter (W) | 14.3 |
| `PPBR` | flt | battery power (W) | 0.5 |
| `PHPC`, `PHPS` | flt | power rails (W) | 6.4, 5.6 |

Under full CPU + GPU load the M5 Max drew ~100 W from a 90 W adapter, with the battery covering the rest.

## Battery (IORegistry, not SMC)

Battery data comes from the `AppleSmartBattery` IORegistry entry, read with `IORegistryEntryCreateCFProperty`:

| Property | Meaning |
|---|---|
| `Voltage` | battery voltage (mV) |
| `InstantAmperage` | current (mA, signed 64-bit; negative while discharging — `ioreg` prints it as a huge unsigned number) |
| `CurrentCapacity` | charge percentage on Apple Silicon |
| `IsCharging`, `ExternalConnected` | flags |
| `AdapterDetails.Watts` | adapter rating (W) |

Battery power is `Voltage × InstantAmperage / 1,000,000` W. The current is averaged by the battery gauge and lags a few seconds behind the actual load.

## Contributing a key dump

Run these on your Mac and attach the output to a hardware report:

```bash
sysctl -n hw.model machdep.cpu.brand_string
```
```bash
/Library/PrivilegedHelperTools/smcfand keys F
```
```bash
/Library/PrivilegedHelperTools/smcfand keys P | head -40
```

(Use `build/smcfan` instead if you built from source and haven't installed the service.)
