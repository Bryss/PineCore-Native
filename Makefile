# Cross-build MeshCore's Linux companion (meshcored) for the WiFi Pineapple Pager
# (OpenWrt 24.10, mipsel_24kc, musl) with the CH341 radio HAL. Mirrors the
# meshcore-linux PlatformIO "linux" env, which PlatformIO can't target here.
# Run via scripts/build.sh (OpenWrt SDK in Docker).

CROSS   ?= mipsel-openwrt-linux-musl-
CC      := $(CROSS)gcc
CXX     := $(CROSS)g++
TP      := third_party
OUT     ?= build
LIBUSB  ?= $(OUT)/libusb
VERSION ?= dev

ARDU := $(TP)/ardulinux/cores
MC   := $(TP)/meshcore

# Like ArduLinux's PlatformIO builder: overlay the Arduino API headers minus
# Print.h, so "Print.h" resolves to ArduLinux's copy (which adds printf()).
API_OVERLAY := $(OUT)/patched_api
API_HEADERS := $(filter-out Print.h,$(notdir $(wildcard $(ARDU)/arduino/api/*)))

ARDULINUX_SRC := \
  $(addprefix $(API_OVERLAY)/,Common.cpp IPAddress.cpp Print.cpp Stream.cpp String.cpp) \
  $(addprefix $(ARDU)/ardulinux/,HardwareSPIStubs.cpp itoa.cpp dtostrf.c logging.cpp Utility.cpp \
    AppInfo.cpp XDGDirs.cpp ArduLinuxGPIO.cpp main.cpp main_entry.cpp \
    FS/ArduLinuxFS.cpp FS/FS.cpp FS/vfs_api.cpp \
    linux/millis.cpp linux/LinuxCommon.cpp linux/LinuxSerial.cpp linux/LinuxHardwareSPI.cpp \
    simulated/SimCommon.cpp simulated/SimHardwareSPI.cpp simulated/SimHardwareI2C.cpp)

MESHCORE_SRC := \
  $(wildcard $(MC)/src/*.cpp) \
  $(wildcard $(MC)/src/helpers/*.cpp) \
  $(wildcard $(MC)/src/helpers/radiolib/*.cpp) \
  $(MC)/src/helpers/bridges/BridgeBase.cpp \
  $(MC)/src/helpers/ui/MomentaryButton.cpp \
  $(MC)/src/helpers/sensors/EnvironmentSensorManager.cpp \
  $(wildcard $(MC)/variants/linux/*.cpp) \
  $(wildcard $(MC)/examples/companion_radio/*.cpp) \
  $(wildcard $(MC)/lib/ed25519/*.c)

LIB_SRC := \
  $(shell find $(TP)/RadioLib/src -name '*.cpp') \
  $(wildcard $(TP)/arduinolibs/libraries/Crypto/*.cpp) \
  $(wildcard $(TP)/CayenneLPP/src/*.cpp) \
  $(TP)/RTClib/src/RTClib.cpp $(TP)/RTClib/src/RTC_DS1307.cpp $(TP)/RTClib/src/RTC_DS3231.cpp \
  $(TP)/RTClib/src/RTC_PCF8523.cpp $(TP)/RTClib/src/RTC_PCF8563.cpp $(TP)/RTClib/src/RTC_Micros.cpp \
  $(TP)/RTClib/src/RTC_Millis.cpp $(TP)/BusIO/Adafruit_I2CDevice.cpp \
  $(wildcard $(TP)/RV3028/src/*.cpp)

PAGER_SRC := src/CH341Hal.cpp

SRC  := $(ARDULINUX_SRC) $(MESHCORE_SRC) $(LIB_SRC) $(PAGER_SRC)
OBJ  := $(patsubst %,$(OUT)/obj/%.o,$(SRC))

# Arduino's api/String.h must not shadow <string.h> on case-insensitive hosts
# (the tree is bind-mounted from macOS), so that directory is searched last.
INCLUDES := -Icompat -Isrc -idirafter $(API_OVERLAY) \
  -I$(ARDU)/ardulinux -I$(ARDU)/ardulinux/FS \
  -I$(TP)/ardulinux/libraries/Wire/src -I$(TP)/ardulinux/libraries/SPI/src \
  -I$(MC)/src -I$(MC)/variants/linux -I$(MC)/examples/companion_radio -I$(MC)/lib/ed25519 \
  -I$(TP)/RadioLib/src -I$(TP)/arduinolibs/libraries/Crypto -I$(TP)/CayenneLPP/src \
  -I$(TP)/ArduinoJson/src -I$(TP)/base64/src -I$(TP)/RTClib/src -I$(TP)/BusIO -I$(TP)/RV3028/src \
  -I$(LIBUSB)/include/libusb-1.0

# arduino_base + linux_base + env:linux flags from meshcore's platformio.ini,
# plus PAGER_CH341 for the Pager radio path.
DEFINES := -DNDEBUG -DHOST -DARDUINO=10810 -DARDULINUX_PLATFORM -DPAGER_CH341 \
  -DRADIOLIB_STATIC_ONLY=1 -DRADIOLIB_GODMODE=1 -DRADIOLIB_EEPROM_UNSUPPORTED \
  -DLORA_FREQ=869.618 -DLORA_BW=62.5 -DLORA_SF=8 -DLORA_CR=8 \
  -DRADIO_FREQ_MIN_KHZ=850000 -DRADIO_FREQ_MAX_KHZ=930000 \
  -DENABLE_ADVERT_ON_BOOT=1 -DENABLE_PRIVATE_KEY_IMPORT=1 -DENABLE_PRIVATE_KEY_EXPORT=1 \
  -DRADIOLIB_EXCLUDE_CC1101=1 -DRADIOLIB_EXCLUDE_RF69=1 -DRADIOLIB_EXCLUDE_SX1231=1 \
  -DRADIOLIB_EXCLUDE_SI443X=1 -DRADIOLIB_EXCLUDE_RFM2X=1 -DRADIOLIB_EXCLUDE_SX128X=1 \
  -DRADIOLIB_EXCLUDE_AFSK=1 -DRADIOLIB_EXCLUDE_AX25=1 -DRADIOLIB_EXCLUDE_HELLSCHREIBER=1 \
  -DRADIOLIB_EXCLUDE_MORSE=1 -DRADIOLIB_EXCLUDE_APRS=1 -DRADIOLIB_EXCLUDE_BELL=1 \
  -DRADIOLIB_EXCLUDE_RTTY=1 -DRADIOLIB_EXCLUDE_SSTV=1 \
  -DRADIO_CLASS=LinuxSX1262 -DWRAPPER_CLASS=LinuxSX1262Wrapper -DUSE_CUSTOM_SX1262_WRAPPER \
  -DSKIP_CONFIG_OVERWRITE=1 -DMAX_CONTACTS=350 -DMAX_GROUP_CHANNELS=40 \
  -DOFFLINE_QUEUE_SIZE=256 -DLORA_TX_POWER=22 \
  '-DFIRMWARE_VERSION="$(VERSION)"'

COMMON  := -Os -w -MMD -MP -ffunction-sections -fdata-sections -pthread $(DEFINES) $(INCLUDES)
CFLAGS  := $(COMMON) -std=gnu17
CXXFLAGS:= $(COMMON) -std=gnu++17
LDFLAGS := -static -pthread -Wl,--gc-sections -s

all: $(OUT)/meshcored

$(API_OVERLAY)/.stamp: $(wildcard $(ARDU)/arduino/api/*)
	rm -rf $(API_OVERLAY) && mkdir -p $(API_OVERLAY)
	for h in $(API_HEADERS); do ln -s "$(CURDIR)/$(ARDU)/arduino/api/$$h" "$(API_OVERLAY)/$$h"; done
	touch $@

# Rebuild everything when the compiler flags change.
FLAGS_STAMP := $(OUT)/.flags-$(shell echo '$(CXXFLAGS) $(CFLAGS)' | md5sum | cut -c1-12)
$(FLAGS_STAMP):
	@mkdir -p $(OUT) && rm -f $(OUT)/.flags-* && touch $@

$(OBJ): $(API_OVERLAY)/.stamp $(FLAGS_STAMP)

$(OUT)/meshcored: $(OBJ) $(LIBUSB)/lib/libusb-1.0.a
	$(CXX) $(LDFLAGS) -o $@ $(OBJ) $(LIBUSB)/lib/libusb-1.0.a -Wl,--start-group -lstdc++ -lgcc -lgcc_eh -lc -Wl,--end-group

$(OUT)/obj/%.cpp.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(OUT)/obj/%.c.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

-include $(OBJ:.o=.d)

clean:
	rm -rf $(OUT)/obj $(OUT)/meshcored

.PHONY: all clean
