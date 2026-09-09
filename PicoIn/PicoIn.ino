// PicoIn (v2): USB Host keyboard+mouse -> framed UART HID reports
// UART A (LED15): Serial2 GP8 (TX) / GP9 (RX) @ 115200
// UART B (LED16): Serial1 GP0 (TX) / GP1 (RX) @ 115200
//
// Frame: [0xAA][TYPE][PAYLOAD...][CHK]
//   TYPE 0x01 keyboard: 8-byte boot report
//   TYPE 0x02 mouse:    4-byte buttons,dx,dy,wheel
// No ACK (fire-and-forget).
//
// Route select (sticky):
//   GP14 -> LED15 on, LED16 off  -> only Serial2
//   GP17 -> LED16 on, LED15 off  -> only Serial1
//   both -> both LEDs on (chordLatched) -> Serial1+Serial2
//   while chordLatched and any held: stay dual; clear latch when both released
//   dual selection stays on LEDs until next press
//   when an LED turns off: send idle kbd+mouse on that UART (no stuck keys)
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

const int BTN_LEFT = 14;
const int BTN_RIGHT = 17;
const int LED_LEFT = 15;   // LED15 <-> Serial2
const int LED_RIGHT = 16;  // LED16 <-> Serial1

static bool led15On = false;
static bool led16On = false;
static bool chordLatched = false;
static bool btnLeftPrev = false;
static bool btnRightPrev = false;

static const uint8_t KBD_IDLE[8] = {0};
static const uint8_t MOUSE_IDLE[4] = {0};

static void writeFrameTo(Stream &port, uint8_t type, const uint8_t *payload, uint8_t len) {
  uint8_t chk = type;
  port.write(FRAME_SYNC);
  port.write(type);
  for (uint8_t i = 0; i < len; i++) {
    port.write(payload[i]);
    chk ^= payload[i];
  }
  port.write(chk);
}

static void sendClearTo(Stream &port) {
  writeFrameTo(port, TYPE_KEYBOARD, KBD_IDLE, 8);
  writeFrameTo(port, TYPE_MOUSE, MOUSE_IDLE, 4);
}

static void applyLedState(bool leftOn, bool rightOn) {
  if (led15On && !leftOn) {
    sendClearTo(Serial2);
  }
  if (led16On && !rightOn) {
    sendClearTo(Serial1);
  }
  led15On = leftOn;
  led16On = rightOn;
  digitalWrite(LED_LEFT, leftOn ? HIGH : LOW);
  digitalWrite(LED_RIGHT, rightOn ? HIGH : LOW);
}

static void sendFrame(uint8_t type, const uint8_t *payload, uint8_t len) {
  if (led15On) {
    writeFrameTo(Serial2, type, payload, len);
  }
  if (led16On) {
    writeFrameTo(Serial1, type, payload, len);
  }
}

static void sendKeyboardReport(const uint8_t *report8) {
  sendFrame(TYPE_KEYBOARD, report8, 8);
}

static void sendMouseReport(const uint8_t *report, uint16_t len) {
  const uint8_t *p = report;
  uint16_t n = len;
  if (n >= 5 && p[0] >= 1 && p[0] <= 15) {
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

static void updateRouteButtons() {
  const bool left = digitalRead(BTN_LEFT) == LOW;
  const bool right = digitalRead(BTN_RIGHT) == LOW;

  if (left && right) {
    chordLatched = true;
    applyLedState(true, true);
  } else if (chordLatched) {
    applyLedState(true, true);
    if (!left && !right) {
      chordLatched = false;
    }
  } else if (left && !btnLeftPrev) {
    applyLedState(true, false);
  } else if (right && !btnRightPrev) {
    applyLedState(false, true);
  }

  btnLeftPrev = left;
  btnRightPrev = right;
}

void setup() {
  pinMode(BTN_LEFT, INPUT_PULLUP);
  pinMode(BTN_RIGHT, INPUT_PULLUP);
  pinMode(LED_LEFT, OUTPUT);
  pinMode(LED_RIGHT, OUTPUT);
  digitalWrite(LED_LEFT, LOW);
  digitalWrite(LED_RIGHT, LOW);

  Serial2.setTX(8);
  Serial2.setRX(9);
  Serial2.begin(115200);

  Serial1.setTX(0);
  Serial1.setRX(1);
  Serial1.begin(115200);

  USBHost.begin(0);
}

void loop() {
  USBHost.task();
  updateRouteButtons();
}

void tuh_hid_mount_cb(uint8_t dev_addr, uint8_t instance,
                      uint8_t const *desc_report, uint16_t desc_len) {
  (void)desc_report;
  (void)desc_len;

  uint8_t const proto = tuh_hid_interface_protocol(dev_addr, instance);
  if (proto == HID_ITF_PROTOCOL_MOUSE) {
    tuh_hid_set_protocol(dev_addr, instance, HID_PROTOCOL_REPORT);
    tuh_hid_receive_report(dev_addr, instance);
  } else if (proto == HID_ITF_PROTOCOL_KEYBOARD) {
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
