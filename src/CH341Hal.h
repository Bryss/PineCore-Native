#pragma once

// RadioLib HAL for an SX126x behind a WCH CH341 USB-to-SPI bridge (USB 1a86:5512),
// as on the Glytch Mesh Mod for the WiFi Pineapple Pager.
//
// SPI and GPIO go over libusb in userspace (the Pager has no spidev/libgpiod for
// the radio). Pins are the CH341's D0..D7: D0..D5 can be outputs, D6/D7 are
// inputs only. D3 (SCK) and D5 (MOSI) belong to the SPI engine and are held as
// idle-high outputs. The CH341 has no interrupt line, so attachInterrupt() runs
// a poll thread that reads the pin and calls the handler on the chosen edge.
//
// Protocol reference: openhop_core's MIT-licensed CH341 driver
// (openhop_core/hardware/ch341/ch341_async.py).

#include <RadioLib.h>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <thread>

struct libusb_context;
struct libusb_device_handle;

class CH341Hal : public RadioLibHal {
public:
  static constexpr uint16_t VID = 0x1A86;
  static constexpr uint16_t PID = 0x5512;

  // Arduino-style mode/level/edge constants for RadioLibHal.
  static constexpr uint32_t MODE_INPUT = 0;
  static constexpr uint32_t MODE_OUTPUT = 1;
  static constexpr uint32_t EDGE_RISING = 1;
  static constexpr uint32_t EDGE_FALLING = 2;

  explicit CH341Hal(uint32_t irq_poll_us = 20000);
  ~CH341Hal() override;

  // Find the bridge, detach the Pager's kernel driver (mphsi-ch34x) and claim it.
  bool open();
  void close();
  bool isOpen() const { return handle_ != nullptr; }

  void pinMode(uint32_t pin, uint32_t mode) override;
  void digitalWrite(uint32_t pin, uint32_t value) override;
  uint32_t digitalRead(uint32_t pin) override;
  void attachInterrupt(uint32_t interruptNum, void (*interruptCb)(void), uint32_t mode) override;
  void detachInterrupt(uint32_t interruptNum) override;
  void delay(RadioLibTime_t ms) override;
  void delayMicroseconds(RadioLibTime_t us) override;
  RadioLibTime_t millis() override;
  RadioLibTime_t micros() override;
  long pulseIn(uint32_t pin, uint32_t state, RadioLibTime_t timeout) override;
  void spiBegin() override {}
  void spiBeginTransaction() override;
  void spiTransfer(uint8_t* out, size_t len, uint8_t* in) override;
  void spiEndTransaction() override;
  void spiEnd() override {}
  void yield() override {}

  // Counters for diagnostics.
  std::atomic<uint32_t> usb_errors{0};
  std::atomic<uint32_t> irq_count{0};

private:
  bool uioStream(bool set_out, bool set_dir);
  bool readPins(uint8_t& pins);
  bool bulkWrite(const uint8_t* data, int len);
  bool bulkRead(uint8_t* data, int len, unsigned timeout_ms);
  void pollLoop();
  void stopPolling();

  libusb_context* ctx_ = nullptr;
  libusb_device_handle* handle_ = nullptr;
  bool kernel_driver_detached_ = false;

  // One USB transaction (write + matching read) at a time. Recursive so a SPI
  // transaction can hold it across CS toggles and transfers.
  std::recursive_mutex usb_lock_;
  uint8_t dir_ = 0;    // 1 = output
  uint8_t state_ = 0;  // output levels

  uint32_t irq_poll_us_;
  std::thread poll_thread_;
  std::atomic<bool> polling_{false};
  uint32_t irq_pin_ = RADIOLIB_NC;
  uint32_t irq_mode_ = EDGE_RISING;
  void (*irq_cb_)(void) = nullptr;
};
