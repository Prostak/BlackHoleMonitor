// PicoIn (v2): USB Host keyboard+mouse -> framed UART HID reports
// UART: Serial2 GP8 (TX) / GP9 (RX) @ 115200 -> PicoOut Serial1 GP0/GP1
//
// Frame: [0xAA][TYPE][PAYLOAD...][CHK]
//   TYPE 0x01 keyboard: 8-byte boot report
//   TYPE 0x02 mouse:    4-byte buttons,dx,dy,wheel (pad wheel=0 if absent)
//   CHK = XOR of TYPE..last payload byte
// No ACK (fire-and-forget).
//
// Tools -> USB Stack -> Adafruit TinyUSB Host (native)
// Upload via BOOTSEL.

#include <string.h>

#include "Adafruit_TinyUSB.h"

#ifndef USE_TINYUSB_HOST
#error "Tools -> USB Stack -> Adafruit TinyUSB Host (native)"
#endif

Adafruit_USBH_Host USBHost;

static const uint8_t FRAME_SYNC = 0xAA;
static const uint8_t TYPE_KEYBOARD = 0x01;
static const uint8_t TYPE_MOUSE = 0x02;

static void sendFrame(uint8_t type, const uint8_t *payload, uint8_t len) {
  uint8_t chk = type;
  Serial2.write(FRAME_SYNC);
  Serial2.write(type);
  for (uint8_t i = 0; i < len; i++) {
    Serial2.write(payload[i]);
    chk ^= payload[i];
  }
  Serial2.write(chk);
}

static void sendKeyboardReport(const uint8_t *report8) {
  sendFrame(TYPE_KEYBOARD, report8, 8);
}

static void sendMouseReport(const uint8_t *report, uint16_t len) {
  // Report protocol: usually [buttons][dx][dy][wheel]
  // Some mice prefix a report ID (1 byte).
  const uint8_t *p = report;
  uint16_t n = len;
  if (n >= 5 && p[0] >= 1 && p[0] <= 15) {
    // Likely report ID; payload follows
    p++;
    n--;
  }

  uint8_t payload[4] = {0, 0, 0, 0};
  if (n >= 1) {
    payload[0] = p[0];
  }
  if (n >= 2) {
    payload[1] = p[1];
  }
  if (n >= 3) {
    payload[2] = p[2];
  }
  if (n >= 4) {
    payload[3] = p[3];
  }
  sendFrame(TYPE_MOUSE, payload, 4);
}

void setup() {
  Serial2.setTX(8);
  Serial2.setRX(9);
  Serial2.begin(115200);

  USBHost.begin(0);
}

void loop() {
  USBHost.task();
}

void tuh_hid_mount_cb(uint8_t dev_addr, uint8_t instance,
                      uint8_t const *desc_report, uint16_t desc_len) {
  (void)desc_report;
  (void)desc_len;

  uint8_t const proto = tuh_hid_interface_protocol(dev_addr, instance);
  if (proto == HID_ITF_PROTOCOL_MOUSE) {
    // Boot mouse is 3 bytes (no wheel). Report protocol includes wheel.
    tuh_hid_set_protocol(dev_addr, instance, HID_PROTOCOL_REPORT);
    tuh_hid_receive_report(dev_addr, instance);
  } else if (proto == HID_ITF_PROTOCOL_KEYBOARD) {
    // Keep boot keyboard (fixed 8-byte reports).
    tuh_hid_receive_report(dev_addr, instance);
  }
}

void tuh_hid_umount_cb(uint8_t dev_addr, uint8_t instance) {
  (void)dev_addr;
  (void)instance;
}

void tuh_hid_report_received_cb(uint8_t dev_addr, uint8_t instance,
                                uint8_t const *report, uint16_t len) {
  uint8_t const proto = tuh_hid_interface_protocol(dev_addr, instance);

  if (proto == HID_ITF_PROTOCOL_KEYBOARD && len >= 8) {
    sendKeyboardReport(report);
  } else if (proto == HID_ITF_PROTOCOL_MOUSE && len >= 3) {
    sendMouseReport(report, len);
  }

  tuh_hid_receive_report(dev_addr, instance);
}
