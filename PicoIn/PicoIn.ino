// Pico In: USB Host keyboard + test buttons -> UART
// UART: Serial2 on GP8 (TX) / GP9 (RX) @ 115200 -> Pico Out Serial1 GP0/GP1
//
// Buttons (test, kept):
//   GP14 held -> LED15; press edge -> 'A'
//   GP17 held -> LED16; press edge -> 'B'
// Keyboard: printable ASCII key-down -> same UART
//
// Tools -> Board: Raspberry Pi Pico/... (Philhower)
// Tools -> USB Stack -> Adafruit TinyUSB Host (native)
// Upload via BOOTSEL (USB Serial unavailable in Host mode).

#include "Adafruit_TinyUSB.h"

#ifndef USE_TINYUSB_HOST
#error "Tools -> USB Stack -> Adafruit TinyUSB Host (native)"
#endif

Adafruit_USBH_Host USBHost;

const int BTN_LEFT = 14;
const int BTN_RIGHT = 17;
const int LED_LEFT = 15;
const int LED_RIGHT = 16;

bool leftPrev = false;
bool rightPrev = false;

static uint8_t const keycode2ascii[128][2] = {HID_KEYCODE_TO_ASCII};

static bool key_in_report(hid_keyboard_report_t const *report, uint8_t keycode) {
  for (uint8_t i = 0; i < 6; i++) {
    if (report->keycode[i] == keycode) {
      return true;
    }
  }
  return false;
}

static void process_kbd_report(hid_keyboard_report_t const *report) {
  static hid_keyboard_report_t prev = {0};

  for (uint8_t i = 0; i < 6; i++) {
    uint8_t key = report->keycode[i];
    if (key == 0 || key_in_report(&prev, key)) {
      continue;
    }

    bool shift = report->modifier & (KEYBOARD_MODIFIER_LEFTSHIFT | KEYBOARD_MODIFIER_RIGHTSHIFT);
    uint8_t ch = keycode2ascii[key][shift ? 1 : 0];
    if (ch) {
      Serial2.write(ch);
    }
  }

  prev = *report;
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

  // Native USB as host (hub + keyboard on Pico USB jack)
  USBHost.begin(0);
}

void loop() {
  USBHost.task();

  bool left = digitalRead(BTN_LEFT) == LOW;
  bool right = digitalRead(BTN_RIGHT) == LOW;

  digitalWrite(LED_LEFT, left ? HIGH : LOW);
  digitalWrite(LED_RIGHT, right ? HIGH : LOW);

  if (left && !leftPrev) {
    Serial2.write('A');
  }
  if (right && !rightPrev) {
    Serial2.write('B');
  }

  leftPrev = left;
  rightPrev = right;
}

void tuh_hid_mount_cb(uint8_t dev_addr, uint8_t instance,
                      uint8_t const *desc_report, uint16_t desc_len) {
  (void)desc_report;
  (void)desc_len;

  if (tuh_hid_interface_protocol(dev_addr, instance) == HID_ITF_PROTOCOL_KEYBOARD) {
    tuh_hid_receive_report(dev_addr, instance);
  }
}

void tuh_hid_umount_cb(uint8_t dev_addr, uint8_t instance) {
  (void)dev_addr;
  (void)instance;
}

void tuh_hid_report_received_cb(uint8_t dev_addr, uint8_t instance,
                                uint8_t const *report, uint16_t len) {
  if (len >= sizeof(hid_keyboard_report_t) &&
      tuh_hid_interface_protocol(dev_addr, instance) == HID_ITF_PROTOCOL_KEYBOARD) {
    process_kbd_report((hid_keyboard_report_t const *)report);
  }
  tuh_hid_receive_report(dev_addr, instance);
}
