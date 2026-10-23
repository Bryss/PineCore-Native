# PineCore Native

**The real MeshCore companion firmware, running natively on the WiFi Pineapple Pager with the Glytch Mesh Mod.**

One static 970 KB binary. The MeshCore app connects to the Pager over Wi-Fi exactly as it would to
any WiFi companion radio, and the Pager becomes a full MeshCore node: contacts, DMs with
delivery ACKs, channels, an offline message queue, and the same firmware code real MeshCore radios run.

> [!CAUTION]
> **VIBE-CODED PROOF OF CONCEPT. NOT A FINISHED, PROPERLY TESTED PRODUCT.**
>
> An AI assistant wrote this in one session. **It has never exchanged a packet with another MeshCore
> node.** Only one Mesh Mod was available, and no other MeshCore nodes were in range.
>
> Checked on one Pager with the Mesh Mod attached:
> - installs offline from the payload; the SX1262 initialises over the CH341 bridge
> - the **MeshCore phone app** connects over TCP, channels work, and the battery % shows (one user, one phone)
> - 16 protocol/hardware checks via the `meshcore` Python client: two transmissions (flood advert +
>   private-channel message at 10 dBm) completed by the radio; it returns to RX; live retune;
>   out-of-band frequencies refused; name, identity and radio settings persist across restarts
> - idle CPU about 5% and RAM about 1 MB (measured); the Pager kept charging on laptop USB while it ran
>
> Not verified: receiving real packets, interop with real nodes, actual RF output and antenna path,
> which E22 variant the Mod uses, long-term stability. Check your radio settings are legal where you
> are before transmitting. Use at your own risk; no support, no warranty.

```
MeshCore app / meshcore-cli ──TCP 172.16.52.1:5000──▶ Pager: meshcored ──libusb──▶ Mesh Mod (CH341 → SX1262) ))) MeshCore mesh
```

## Comparison

All measured on the same Pager model and Mesh Mod at idle, averaged over 30 s. The Pager itself idles at about 4% CPU.

| | **PineCore Native (this)** | [PineCore](https://github.com/Bryss/PineCore) (Python, deprecated) | Glytch Meshtastic (reference) |
|---|---|---|---|
| Stack | MeshCore companion firmware, C++ ([meshcore-linux](https://github.com/l5yth/meshcore-linux)) | [openhop_core](https://github.com/pyMC-dev/pyMC_core) (Python MeshCore) | `meshtasticd` 2.7.26 |
| Daemon CPU, idle | **~5%** | ~45% | ~2% |
| Memory (RSS) | **1 MB** | 20 MB | 7.5 MB |
| Install footprint | **~0.5 MB** (one static binary) | ~7.5 MB (Python runtime) | opkg packages |
| Needs internet to install | **no** (binary ships in the payload) | yes | yes |
| Time to start | **~6 s** | tens of seconds | |
| Phone app | MeshCore app, TCP 5000 | MeshCore app, TCP 5000 | Meshtastic app, TCP 4403 |

IRQ poll interval vs CPU for this build (`MESHCORED_IRQ_POLL_MS`):

| Poll | 5 ms | 10 ms | **20 ms (default)** | 50 ms |
|---|---|---|---|---|
| meshcored CPU | 10.5% | 7.0% | **5.0%** | 3.7% |

## Install

1. Attach the Mesh Mod **with its antenna on**. Never transmit without an antenna.
2. Copy the payload folder to the Pager. The binary is inside, so no internet is needed:
   ```sh
   scp -O -r payload/MeshCoreNative root@172.16.52.1:/root/payloads/user/general/
   ```
3. On the Pager: **Payloads → General → MeshCoreNative → Install / Update**, then **Start server**.
4. Join the Pager's **management Wi-Fi** from your phone (the Mod occupies the USB port), open the
   MeshCore app, and connect via **TCP** to `172.16.52.1` port `5000`.
5. Set your name, **radio region** and **TX power** in the app, as with any MeshCore companion.

`meshcore-cli` works too: `meshcore-cli -t 172.16.52.1 -p 5000 infos`.

**First-boot defaults:** EU/UK (Narrow) 869.618 MHz / BW 62.5 / SF8 / CR8, **22 dBm**, and, as with
upstream companion firmware, **one advert at boot**. If your Mod is a high-power E22-…M30S, 22 dBm on
the chip is about 30 dBm out, so lower it in the app (EU 869.4–869.65 MHz allows 500 mW ERP). Outside
Europe, change the region in the app before you rely on it.

### Payload menu

| Item | What it does |
|---|---|
| Start server / Stop server | run or stop `meshcored` (procd-supervised, auto-respawn) |
| Show contact QR | a `meshcore://contact/add…` QR (from the stored public key) to scan in the app |
| Status | running state, key, boot setting, Mesh Mod detection |
| Install / Update | verifies `SHA256SUMS`, installs `/usr/bin/meshcored` and the init script; keeps state and config |
| Enable at Boot | default OFF |
| Uninstall | removes the binary and service; keeps identity, contacts and `/etc/meshcored/meshcored.ini` |

Command line: `payload.sh --install | --start | --stop | --status | --qr | --boot-on | --boot-off | --uninstall`.

### Files on the Pager

| Path | What |
|---|---|
| `/usr/bin/meshcored` | the daemon (static MIPS binary) |
| `/etc/meshcored/meshcored.ini` | hardware config: CH341 pins, TCXO, RF switch, TCP port/bind |
| `/root/.meshcored/` | node state on the eMMC: identity, prefs, contacts, channels |
| `/etc/init.d/meshcored`, `/etc/config/meshcored` | procd service and the boot setting |

Logs: `logread | grep meshcored`. Only one of Meshtastic, PineCore and this can own the Mesh Mod at a
time; Start refuses while another one runs.

## How it works

[l5yth/meshcore-linux](https://github.com/l5yth/meshcore-linux) builds MeshCore's own companion
firmware as a Linux daemon on [ArduLinux](https://github.com/l5yth/ardulinux), an Arduino API for
Linux, with a native TCP companion listener. It drives the radio through kernel `spidev` + `libgpiod`,
like a Raspberry Pi HAT. The Pager has neither: the Mesh Mod's SX1262 sits behind a **CH341
USB-to-SPI bridge**. This repo adds:

- **`src/CH341Hal.*`, a RadioLib HAL over libusb.** It sends SPI as CH341 `0xA8` stream packets
  (bit-reversed, 31-byte chunks), GPIO via `0xAB` UIO stream and `0xA0` pin reads. Pins are CH341 D0–D7:
  CS 0, RXEN 1, RESET 2, BUSY 4, IRQ 6, the same wiring as Meshtastic's `lora-usb-meshtoad-e22`. It
  detaches the Pager's `mphsi-ch34x` kernel driver and claims the bridge. The CH341 has no interrupt
  line, so IRQs come from a poll thread (20 ms); the SX1262 latches DIO1 until cleared, so slower polling
  adds latency but loses nothing.
- **`patches/meshcore-pager-ch341.patch`, 60 lines on upstream:**
  - `PAGER_CH341` board path: open the CH341 instead of spidev/gpiod; battery from the Pager's bq27546 fuel gauge
  - an 850–930 MHz band guard in the companion (and on load), since the chip tunes 150–960 MHz but this module's RF path doesn't
  - **upstream bug fix:** the companion never created `/identity` on Linux, so every restart produced a new node identity
- **`compat/argp.h`**: a small getopt-based argp, since musl has none.
- **A cross-build** (Makefile + the official OpenWrt 24.10.1 SDK in Docker) that reproduces
  meshcore-linux's PlatformIO `linux` env for mipsel_24kc/musl, statically linked with libusb.

## Build

Needs Docker. Apple Silicon works: the amd64 SDK image runs under emulation, and a clean build takes a few minutes.

```sh
scripts/build.sh
```

That fetches every dependency at a pinned revision (`scripts/fetch-sources.sh`), applies the patch,
builds static libusb and `meshcored` in the SDK container, copies the binary into
`payload/MeshCoreNative/` and writes `SHA256SUMS`. `third_party/` and `build/` aren't committed.

Testing against a running Pager: `tests/hw_smoke.py` (needs `pip install meshcore`). **It transmits**:
one advert and one private-channel message at 10 dBm.

## Contributing

This was built in one sitting to get MeshCore running on the Pager properly. It's here to get the
community going: **fork it, improve it, break it, send PRs**, or just open an issue with what you
saw on your hardware. Useful directions:

- **Real-world testing.** The biggest gap. If you have a Pager, a Mesh Mod and MeshCore nodes nearby,
  report back: adverts heard both ways, DMs delivered with ACKs, range, stability over days.
- **Upstream it.** The identity fix and the CH341 HAL belong in
  [meshcore-linux](https://github.com/l5yth/meshcore-linux). The HAL would also give any Linux box
  with a CH341 LoRa stick (Meshtoad and friends) native MeshCore.
- **Cut CPU further.** Fold CS toggles into the SPI stream packets (fewer USB round trips), or poll
  the IRQ pin less while idle.
- **Repeater / room server builds** from the same tree (`linux_repeater` env), for a solar Pager relay.
- **Pager UI:** show incoming messages on the Pager's screen and reply from its buttons.
- **CI and releases:** GitHub Actions building the binary, release assets, an OpenWrt `.ipk`, or
  getting the payload into Hak5's payload library.

## Licences

This repo's own code (`src/`, `compat/`, `scripts/`, `payload/`, the patch) is MIT. The bundled
binary statically links MIT components (MeshCore, RadioLib, rweather Crypto, ArduinoJson, CayenneLPP,
base64, RTClib, Adafruit BusIO, Melopero RV3028) and **LGPL-2.1** components (ArduLinux,
ArduinoCore-API, libusb). See [NOTICE.md](NOTICE.md) for revisions and how to rebuild or relink.

## Credits

- [MeshCore](https://github.com/meshcore-dev/MeshCore) and [l5yth/meshcore-linux](https://github.com/l5yth/meshcore-linux) / [ArduLinux](https://github.com/l5yth/ardulinux)
- [RadioLib](https://github.com/jgromes/RadioLib)
- [pyMC / openHop](https://github.com/pyMC-dev/pyMC_core), whose MIT CH341 driver documented the bridge protocol
- [Glytch](https://github.com/glytchtech/Pager-Mod-Docs) for the Mesh Mod and the Meshtastic payload this mirrors
