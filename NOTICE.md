# Third-party components in `payload/MeshCoreNative/meshcored`

The binary is statically linked from these sources, fetched at the exact revisions pinned in
`scripts/fetch-sources.sh`:

| Component | Revision | Licence |
|---|---|---|
| [meshcore-linux](https://github.com/l5yth/meshcore-linux) (MeshCore) + `patches/meshcore-pager-ch341.patch` | 32e9f95 | MIT |
| [ArduLinux](https://github.com/l5yth/ardulinux) | v0.2.3 | LGPL-2.1 |
| [ArduinoCore-API](https://github.com/arduino/ArduinoCore-API) (ArduLinux submodule) | as pinned by ArduLinux v0.2.3 | LGPL-2.1 |
| [libusb](https://github.com/libusb/libusb) | 1.0.27 | LGPL-2.1 |
| [RadioLib](https://github.com/jgromes/RadioLib) | 6d89348 | MIT |
| [rweather Crypto](https://github.com/rweather/arduinolibs) | 37a76b8 | MIT |
| [CayenneLPP](https://github.com/ElectronicCats/CayenneLPP) | 1.6.1 | MIT |
| [ArduinoJson](https://github.com/bblanchon/ArduinoJson) | v7.4.2 | MIT |
| [base64_arduino](https://github.com/Densaugeo/base64_arduino) | 574949c | MIT |
| [RTClib](https://github.com/adafruit/RTClib) | 2.1.4 | MIT |
| [Adafruit BusIO](https://github.com/adafruit/Adafruit_BusIO) | 1.17.0 | MIT |
| [Melopero RV-3028](https://github.com/melopero/Melopero_RV-3028_Arduino_Library) | 1.1.0 | MIT |

**LGPL-2.1 relinking:** because the LGPL components are linked statically, this repository provides
everything needed to rebuild the binary against modified versions of them: the complete build
(`Makefile`, `scripts/build.sh`, the public OpenWrt SDK image) and the exact upstream sources via
`scripts/fetch-sources.sh`. Replace the source under `third_party/` and run `scripts/build.sh`.
