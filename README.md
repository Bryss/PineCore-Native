# PineCore Native

**The real MeshCore companion firmware, running natively on the WiFi Pineapple Pager with the Glytch Mesh Mod.**

> [!CAUTION]
> **VIBE-CODED PROOF OF CONCEPT. NOT A FINISHED, PROPERLY TESTED PRODUCT.**
>
> An AI assistant wrote this in one session. **It has never exchanged a packet with another MeshCore
> node**: only one Mesh Mod was available, and no other MeshCore nodes were in range.
>
> What *was* checked, on one Pager with the Mesh Mod attached:
> - the binary installs and runs from the payload; the SX1262 initialises over the CH341 bridge
> - 16 protocol/hardware checks via the `meshcore` Python client over TCP 5000: two transmissions
>   (flood advert + private-channel message at 10 dBm) completed by the radio; it returns to RX;
>   live retune; out-of-band frequencies refused; name/identity/radio settings persist across restarts
> - idle CPU about 5% and RAM about 1 MB (measured)
> - the MeshCore phone app connects over TCP, channels work and battery % shows (one user, one phone)
>
> Not verified: receiving real packets, interop with real nodes, actual RF output and antenna path,
> and long-term stability. Check your radio settings
> are legal before transmitting. Use at your own risk; no support, no warranty.

## What it is

[l5yth/meshcore-linux](https://github.com/l5yth/meshcore-linux) builds MeshCore's own C++
companion firmware as a Linux daemon (`meshcored`) on the
[ArduLinux](https://github.com/l5yth/ardulinux) Arduino-for-Linux core, with a native TCP companion
listener. It expects kernel `spidev` + `libgpiod` (a Raspberry Pi HAT). The Pager has neither; the
Mesh Mod's SX1262 sits behind a **CH341 USB-to-SPI bridge**.

This repo adds:

- **`src/CH341Hal.*`**: a RadioLib HAL that does SPI and GPIO over libusb (CH341 D0..D7: CS0, RXEN1,
  RESET2, BUSY4, IRQ6, the same wiring as Meshtastic's `lora-usb-meshtoad-e22` profile). The CH341
  has no interrupt line, so IRQ is a 20 ms poll thread; the SX1262 latches DIO1, so no events are lost.
- **`patches/meshcore-pager-ch341.patch`**: about 130 lines, all behind `PAGER_CH341` or generic:
  open the CH341 instead of spidev/gpiod, Pager battery from the bq27546 fuel gauge, a band guard
  (850–930 MHz, refusing e.g. 433 MHz from the app), and **a fix for an upstream bug** where the
  companion never created `/identity` on Linux, so every restart produced a new node identity.
- **`compat/argp.h`**: a tiny getopt-based argp, since musl has none.
- **A cross-build** with the official OpenWrt 24.10.1 SDK in Docker → one **static 970 KB MIPS binary**
  (MeshCore, RadioLib, crypto, libusb, no runtime dependencies).
- **`payload/MeshCoreNative/`**: a Pager payload in the style of Glytch's Meshtastic payload.

## Compared

Measured on the same Pager and Mesh Mod, idle, average over 30 s:

| | CPU (daemon) | RAM | Install size | Start |
|---|---|---|---|---|
| [PineCore](https://github.com/Bryss/PineCore) (Python, openhop_core) | ~45% | 20 MB | ~17 MB + internet | ~50 s |
| **PineCore Native (this, C++)** | **~5%** | **1 MB** | **~0.5 MB, offline** | **~6 s** |
| Glytch Meshtastic (`meshtasticd`, reference) | ~2% | 7.5 MB | | |

## Install

1. Attach the Mesh Mod **with its antenna on**. Never transmit without an antenna.
2. Copy the payload folder (binary included, no internet needed on the Pager):
   ```sh
   scp -O -r payload/MeshCoreNative root@172.16.52.1:/root/payloads/user/general/
   ```
3. On the Pager: **Payloads → General → MeshCoreNative → Install / Update**, then **Start server**.
4. MeshCore app → connect via **TCP** to `172.16.52.1:5000`, over the Pager's management Wi-Fi
   (the Mod occupies the USB port). Set name, region and TX power in the app, like any companion.

First boot defaults: EU/UK (Narrow) 869.618 MHz / BW 62.5 / SF8 / CR8, **22 dBm**, and, as with
upstream companion firmware, **one advert at boot**. If your Mod is a high-power E22-…M30S, 22 dBm on
the chip is about 30 dBm out, so lower it in the app (EU 869.4–869.65 MHz allows 500 mW ERP).

Menu: Start / Stop, Show contact QR (from the stored public key), Status, Install / Update,
Enable at Boot (default OFF), Uninstall (keeps identity, contacts and `/etc/meshcored/meshcored.ini`).
State lives in `/root/.meshcored` on the eMMC. Only one of Meshtastic, PineCore and this can own the
Mesh Mod at a time; Start checks for the others.

Tuning: `MESHCORED_IRQ_POLL_MS` (1–100, default 20) trades IRQ latency for CPU; measured 10.5% at
5 ms, 7% at 10 ms, 5% at 20 ms, 3.7% at 50 ms.

## Build

Needs Docker (Apple Silicon works; the amd64 SDK image runs under emulation, a full build takes a few minutes).

```sh
scripts/build.sh   # fetches pinned sources, builds static libusb + meshcored in the OpenWrt SDK,
                   # copies the binary into payload/MeshCoreNative/ and writes SHA256SUMS
```

`scripts/fetch-sources.sh` pins every dependency to an exact commit/tag and applies the patch;
`third_party/` and `build/` are not committed.

## Licences

This repo's own code (`src/`, `compat/`, `scripts/`, `payload/`, the patch) is MIT. The bundled
binary statically links MIT components (MeshCore, RadioLib, rweather Crypto, ArduinoJson, CayenneLPP,
base64, RTClib, Adafruit BusIO, Melopero RV3028) and **LGPL-2.1** components (ArduLinux,
ArduinoCore-API, libusb). See [NOTICE.md](NOTICE.md).
