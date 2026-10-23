#include "CH341Hal.h"

#include <libusb.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <unistd.h>

namespace {

constexpr uint8_t EP_OUT = 0x02;
constexpr uint8_t EP_IN = 0x82;
constexpr uint8_t CMD_SPI_STREAM = 0xA8;
constexpr uint8_t CMD_UIO_STREAM = 0xAB;
constexpr uint8_t CMD_UIO_READ = 0xA0;
constexpr uint8_t UIO_STM_OUT = 0x80;
constexpr uint8_t UIO_STM_DIR = 0x40;
constexpr uint8_t UIO_STM_END = 0x20;
constexpr int PACKET_PAYLOAD = 31;  // 32-byte packets: command byte + 31 data bytes
constexpr unsigned USB_TIMEOUT_MS = 1000;

// Pins owned by the CH341 SPI engine: D0 = CS (driven by RadioLib), D3 = SCK, D5 = MOSI.
constexpr uint8_t SPI_IDLE_PINS = (1 << 0) | (1 << 3) | (1 << 5);
constexpr uint32_t MAX_OUTPUT_PIN = 5;
constexpr uint32_t MAX_PIN = 7;

// The CH341 shifts bits LSB first; SX126x expects MSB first.
uint8_t reverseBits(uint8_t b) {
  b = (uint8_t)((b & 0xF0) >> 4 | (b & 0x0F) << 4);
  b = (uint8_t)((b & 0xCC) >> 2 | (b & 0x33) << 2);
  b = (uint8_t)((b & 0xAA) >> 1 | (b & 0x55) << 1);
  return b;
}

uint64_t monotonicMicros() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

}  // namespace

CH341Hal::CH341Hal(uint32_t irq_poll_us)
    : RadioLibHal(MODE_INPUT, MODE_OUTPUT, 0, 1, EDGE_RISING, EDGE_FALLING),
      irq_poll_us_(irq_poll_us) {
  // MESHCORED_IRQ_POLL_MS trades IRQ latency for CPU (each poll is two USB transfers).
  if (const char* env = getenv("MESHCORED_IRQ_POLL_MS")) {
    long ms = strtol(env, nullptr, 10);
    if (ms >= 1 && ms <= 100) irq_poll_us_ = (uint32_t)ms * 1000;
  }
}

CH341Hal::~CH341Hal() { close(); }

bool CH341Hal::open() {
  if (handle_) return true;
  if (libusb_init(&ctx_) != 0) {
    fprintf(stderr, "CH341: libusb_init failed\n");
    ctx_ = nullptr;
    return false;
  }
  handle_ = libusb_open_device_with_vid_pid(ctx_, VID, PID);
  if (!handle_) {
    fprintf(stderr, "CH341: Mesh Mod bridge %04x:%04x not found\n", VID, PID);
    close();
    return false;
  }
  // The Pager's mphsi-ch34x driver binds the bridge on plug-in; take it over.
  if (libusb_kernel_driver_active(handle_, 0) == 1) {
    if (libusb_detach_kernel_driver(handle_, 0) == 0) {
      kernel_driver_detached_ = true;
    } else {
      fprintf(stderr, "CH341: could not detach the kernel driver\n");
    }
  }
  int rc = libusb_set_configuration(handle_, 1);
  if (rc != 0 && rc != LIBUSB_ERROR_BUSY) {
    fprintf(stderr, "CH341: set_configuration failed: %s\n", libusb_error_name(rc));
  }
  rc = libusb_claim_interface(handle_, 0);
  if (rc != 0) {
    fprintf(stderr, "CH341: claim_interface failed: %s (is another radio daemon running?)\n",
            libusb_error_name(rc));
    close();
    return false;
  }

  std::lock_guard<std::recursive_mutex> lock(usb_lock_);
  dir_ = SPI_IDLE_PINS;
  state_ = SPI_IDLE_PINS;  // CS deasserted, SCK/MOSI idle high
  uioStream(true, true);
  // Drain anything a previous owner left in the IN endpoint.
  uint8_t junk[64];
  int got = 0;
  for (int i = 0; i < 32; i++) {
    if (libusb_bulk_transfer(handle_, EP_IN, junk, sizeof(junk), &got, 10) != 0 || got == 0) break;
  }
  return true;
}

void CH341Hal::close() {
  stopPolling();
  if (handle_) {
    libusb_release_interface(handle_, 0);
    if (kernel_driver_detached_) libusb_attach_kernel_driver(handle_, 0);
    libusb_close(handle_);
    handle_ = nullptr;
  }
  if (ctx_) {
    libusb_exit(ctx_);
    ctx_ = nullptr;
  }
}

bool CH341Hal::bulkWrite(const uint8_t* data, int len) {
  int done = 0;
  while (done < len) {
    int sent = 0;
    int rc = libusb_bulk_transfer(handle_, EP_OUT, const_cast<uint8_t*>(data) + done, len - done,
                                  &sent, USB_TIMEOUT_MS);
    if (rc != 0 || sent <= 0) {
      usb_errors++;
      return false;
    }
    done += sent;
  }
  return true;
}

bool CH341Hal::bulkRead(uint8_t* data, int len, unsigned timeout_ms) {
  int done = 0;
  while (done < len) {
    int got = 0;
    int rc = libusb_bulk_transfer(handle_, EP_IN, data + done, len - done, &got, timeout_ms);
    if (rc != 0 || got <= 0) {
      usb_errors++;
      return false;
    }
    done += got;
  }
  return true;
}

bool CH341Hal::uioStream(bool set_out, bool set_dir) {
  uint8_t cmd[4];
  int n = 0;
  cmd[n++] = CMD_UIO_STREAM;
  if (set_out) cmd[n++] = (uint8_t)(UIO_STM_OUT | (state_ & 0x3F));
  if (set_dir) cmd[n++] = (uint8_t)(UIO_STM_DIR | (dir_ & 0x3F));
  cmd[n++] = UIO_STM_END;
  return bulkWrite(cmd, n);
}

bool CH341Hal::readPins(uint8_t& pins) {
  std::lock_guard<std::recursive_mutex> lock(usb_lock_);
  if (!handle_) return false;
  uint8_t cmd = CMD_UIO_READ;
  uint8_t resp[6];
  if (!bulkWrite(&cmd, 1) || !bulkRead(resp, sizeof(resp), 200)) return false;
  pins = resp[0];
  return true;
}

void CH341Hal::pinMode(uint32_t pin, uint32_t mode) {
  if (pin == RADIOLIB_NC || pin > MAX_PIN) return;
  std::lock_guard<std::recursive_mutex> lock(usb_lock_);
  if (mode == MODE_OUTPUT && pin <= MAX_OUTPUT_PIN) {
    dir_ |= (uint8_t)(1u << pin);
  } else {
    dir_ &= (uint8_t)~(1u << pin);
  }
  if (handle_) uioStream(true, true);
}

void CH341Hal::digitalWrite(uint32_t pin, uint32_t value) {
  if (pin == RADIOLIB_NC || pin > MAX_OUTPUT_PIN) return;
  std::lock_guard<std::recursive_mutex> lock(usb_lock_);
  if (value) {
    state_ |= (uint8_t)(1u << pin);
  } else {
    state_ &= (uint8_t)~(1u << pin);
  }
  if (handle_) uioStream(true, false);
}

uint32_t CH341Hal::digitalRead(uint32_t pin) {
  if (pin == RADIOLIB_NC || pin > MAX_PIN) return 0;
  uint8_t pins = 0;
  if (!readPins(pins)) return 0;
  return (pins >> pin) & 1u;
}

void CH341Hal::attachInterrupt(uint32_t interruptNum, void (*interruptCb)(void), uint32_t mode) {
  stopPolling();
  if (interruptNum == RADIOLIB_NC || !interruptCb) return;
  irq_pin_ = interruptNum;
  irq_cb_ = interruptCb;
  irq_mode_ = mode;
  polling_ = true;
  poll_thread_ = std::thread(&CH341Hal::pollLoop, this);
}

void CH341Hal::detachInterrupt(uint32_t interruptNum) {
  (void)interruptNum;
  stopPolling();
}

void CH341Hal::stopPolling() {
  polling_ = false;
  if (poll_thread_.joinable() && poll_thread_.get_id() != std::this_thread::get_id()) {
    poll_thread_.join();
  }
}

void CH341Hal::pollLoop() {
  // The SX126x holds DIO1 high until its IRQ flags are cleared, so a poll
  // period of a few ms only delays handling; it cannot lose an event.
  uint8_t pins = 0;
  bool last = readPins(pins) && ((pins >> irq_pin_) & 1u);
  while (polling_) {
    usleep(irq_poll_us_);
    if (!readPins(pins)) continue;
    bool level = (pins >> irq_pin_) & 1u;
    bool fire = (irq_mode_ == EDGE_RISING && !last && level) ||
                (irq_mode_ == EDGE_FALLING && last && !level);
    last = level;
    if (fire && polling_ && irq_cb_) {
      irq_count++;
      irq_cb_();
    }
  }
}

void CH341Hal::delay(RadioLibTime_t ms) { usleep((useconds_t)ms * 1000); }

void CH341Hal::delayMicroseconds(RadioLibTime_t us) { usleep((useconds_t)us); }

RadioLibTime_t CH341Hal::millis() { return (RadioLibTime_t)(monotonicMicros() / 1000ULL); }

RadioLibTime_t CH341Hal::micros() { return (RadioLibTime_t)monotonicMicros(); }

long CH341Hal::pulseIn(uint32_t pin, uint32_t state, RadioLibTime_t timeout) {
  (void)pin;
  (void)state;
  (void)timeout;
  return 0;  // not used by the SX126x driver
}

void CH341Hal::spiBeginTransaction() { usb_lock_.lock(); }

void CH341Hal::spiEndTransaction() { usb_lock_.unlock(); }

void CH341Hal::spiTransfer(uint8_t* out, size_t len, uint8_t* in) {
  std::lock_guard<std::recursive_mutex> lock(usb_lock_);
  if (!handle_) {
    if (in) memset(in, 0xFF, len);
    return;
  }
  uint8_t packet[1 + PACKET_PAYLOAD];
  uint8_t resp[PACKET_PAYLOAD];
  size_t done = 0;
  while (done < len) {
    int chunk = (int)((len - done) < (size_t)PACKET_PAYLOAD ? (len - done) : PACKET_PAYLOAD);
    packet[0] = CMD_SPI_STREAM;
    for (int i = 0; i < chunk; i++) packet[1 + i] = reverseBits(out ? out[done + i] : 0x00);
    if (!bulkWrite(packet, 1 + chunk) || !bulkRead(resp, chunk, USB_TIMEOUT_MS)) {
      if (in) memset(in + done, 0xFF, len - done);
      return;
    }
    if (in) {
      for (int i = 0; i < chunk; i++) in[done + i] = reverseBits(resp[i]);
    }
    done += (size_t)chunk;
  }
}
