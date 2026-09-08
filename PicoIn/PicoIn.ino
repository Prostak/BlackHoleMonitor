// Pico In: USB Host keyboard + test buttons -> UART with ACK from Pico Out
// UART: Serial2 GP8 (TX) / GP9 (RX) @ 115200 <-> Pico Out Serial1 GP0/GP1
//
// Protocol: send one byte, wait for any ACK echo from Out; count mismatches/timeouts.
// Snapshot: simple ACK bridge + USB inventory dump (Logitech mouse+keyboard seen).
//
// Buttons:
//   GP14 held -> LED15; press edge -> 'A'
//   GP17 held -> LED16; press edge -> USB inventory dump
//
// Tools -> USB Stack -> Adafruit TinyUSB Host (native)
// Upload via BOOTSEL.

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "Adafruit_TinyUSB.h"

#ifndef USE_TINYUSB_HOST
#error "Tools -> USB Stack -> Adafruit TinyUSB Host (native)"
#endif

Adafruit_USBH_Host USBHost;

const int BTN_LEFT = 14;
const int BTN_RIGHT = 17;
const int LED_LEFT = 15;
const int LED_RIGHT = 16;

#define LANGUAGE_ID 0x0409

static const uint32_t ACK_TIMEOUT_MS = 300;

bool leftPrev = false;
bool rightPrev = false;

static uint32_t ackMismatchCount = 0;
static uint32_t ackTimeoutCount = 0;

static uint8_t const keycode2ascii[128][2] = {HID_KEYCODE_TO_ASCII};

static void drainRx() {
  while (Serial2.available()) {
    Serial2.read();
  }
}

// Send one byte, wait for any echo from Out. Mismatch/timeout only counted.
static void uartSendWithAck(uint8_t c) {
  drainRx();
  Serial2.write(c);
  Serial2.flush();

  uint32_t start = millis();
  while ((millis() - start) < ACK_TIMEOUT_MS) {
    USBHost.task();
    if (Serial2.available()) {
      uint8_t back = (uint8_t)Serial2.read();
      if (back != c) {
        ackMismatchCount++;
      }
      return;
    }
  }
  ackTimeoutCount++;
}

//--------------------------------------------------------------------+
// Dump buffer + ACK playback
//--------------------------------------------------------------------+
static char dumpBuf[3072];
static size_t dumpLen = 0;

static void dumpClear() {
  dumpLen = 0;
  dumpBuf[0] = '\0';
}

static void dumpPutChar(char c) {
  if (dumpLen + 1 >= sizeof(dumpBuf)) {
    return;
  }
  if (c == '\n') {
    c = '\r';
  }
  if (c == '\r' || (c >= 32 && c <= 126)) {
    dumpBuf[dumpLen++] = c;
    dumpBuf[dumpLen] = '\0';
  } else {
    dumpBuf[dumpLen++] = '?';
    dumpBuf[dumpLen] = '\0';
  }
}

static void dumpPut(const char *s) {
  if (!s) {
    return;
  }
  while (*s) {
    dumpPutChar(*s++);
  }
}

static void dumpPutAscii(const char *s) {
  if (!s) {
    return;
  }
  while (*s) {
    unsigned char c = (unsigned char)*s++;
    if (c >= 32 && c < 127) {
      dumpPutChar((char)c);
    } else if (c >= 0x80) {
      dumpPutChar('?');
      while ((*s & 0xC0) == 0x80) {
        s++;
      }
    }
  }
}

static void dumpPrintf(const char *fmt, ...) {
  char tmp[192];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(tmp, sizeof(tmp), fmt, ap);
  va_end(ap);
  dumpPut(tmp);
}

static void dumpPlay() {
  for (size_t i = 0; i < dumpLen; i++) {
    uartSendWithAck((uint8_t)dumpBuf[i]);
  }
}

//--------------------------------------------------------------------+
// UTF-16LE string descriptor -> UTF-8
//--------------------------------------------------------------------+
static void convert_utf16le_to_utf8(const uint16_t *utf16, size_t utf16_len,
                                   uint8_t *utf8, size_t utf8_len) {
  (void)utf8_len;
  for (size_t i = 0; i < utf16_len; i++) {
    uint16_t chr = utf16[i];
    if (chr < 0x80) {
      *utf8++ = chr & 0xff;
    } else if (chr < 0x800) {
      *utf8++ = (uint8_t)(0xC0 | (chr >> 6 & 0x1F));
      *utf8++ = (uint8_t)(0x80 | (chr >> 0 & 0x3F));
    } else {
      *utf8++ = (uint8_t)(0xE0 | (chr >> 12 & 0x0F));
      *utf8++ = (uint8_t)(0x80 | (chr >> 6 & 0x3F));
      *utf8++ = (uint8_t)(0x80 | (chr >> 0 & 0x3F));
    }
  }
}

static int count_utf8_bytes(const uint16_t *buf, size_t len) {
  size_t total = 0;
  for (size_t i = 0; i < len; i++) {
    uint16_t chr = buf[i];
    if (chr < 0x80) {
      total += 1;
    } else if (chr < 0x800) {
      total += 2;
    } else {
      total += 3;
    }
  }
  return (int)total;
}

static void utf16_to_utf8(uint16_t *temp_buf, size_t buf_len) {
  size_t utf16_len = ((temp_buf[0] & 0xff) - 2) / sizeof(uint16_t);
  size_t utf8_len = (size_t)count_utf8_bytes(temp_buf + 1, utf16_len);
  convert_utf16le_to_utf8(temp_buf + 1, utf16_len, (uint8_t *)temp_buf, buf_len);
  ((uint8_t *)temp_buf)[utf8_len] = '\0';
}

static const char *hid_protocol_name(uint8_t proto) {
  switch (proto) {
    case HID_ITF_PROTOCOL_NONE:
      return "none generic HID";
    case HID_ITF_PROTOCOL_KEYBOARD:
      return "keyboard boot";
    case HID_ITF_PROTOCOL_MOUSE:
      return "mouse boot";
    default:
      return "unknown";
  }
}

static const char *class_name(uint8_t cls) {
  switch (cls) {
    case 0x00:
      return "per-interface";
    case 0x01:
      return "Audio";
    case 0x02:
      return "CDC";
    case 0x03:
      return "HID";
    case 0x08:
      return "Mass Storage";
    case 0x09:
      return "Hub";
    case 0x0B:
      return "Smart Card";
    case 0x0E:
      return "Video";
    case 0xE0:
      return "Wireless";
    case 0xFF:
      return "Vendor";
    default:
      return "other";
  }
}

static void dump_one_device(uint8_t daddr) {
  tusb_desc_device_t desc;
  if (XFER_RESULT_SUCCESS !=
      tuh_descriptor_get_device_sync(daddr, &desc, sizeof(desc))) {
    dumpPrintf("Device addr %u: descriptor FAILED\r", daddr);
    return;
  }

  dumpPrintf("--- Device address %u ---\r", daddr);
  dumpPrintf("VID:PID %04x:%04x\r", desc.idVendor, desc.idProduct);
  dumpPrintf("bcdUSB %04x\r", desc.bcdUSB);
  dumpPrintf("bDeviceClass %u (%s)\r", desc.bDeviceClass, class_name(desc.bDeviceClass));
  dumpPrintf("bDeviceSubClass %u\r", desc.bDeviceSubClass);
  dumpPrintf("bDeviceProtocol %u\r", desc.bDeviceProtocol);
  dumpPrintf("bMaxPacketSize0 %u\r", desc.bMaxPacketSize0);
  dumpPrintf("bcdDevice %04x\r", desc.bcdDevice);
  dumpPrintf("bNumConfigurations %u\r", desc.bNumConfigurations);

  uint16_t strbuf[64];

  dumpPut("Manufacturer ");
  if (desc.iManufacturer &&
      XFER_RESULT_SUCCESS ==
          tuh_descriptor_get_manufacturer_string_sync(daddr, LANGUAGE_ID, strbuf,
                                                      sizeof(strbuf))) {
    utf16_to_utf8(strbuf, sizeof(strbuf));
    dumpPutAscii((char *)strbuf);
  } else {
    dumpPut("none");
  }
  dumpPutChar('\r');

  dumpPut("Product ");
  if (desc.iProduct &&
      XFER_RESULT_SUCCESS ==
          tuh_descriptor_get_product_string_sync(daddr, LANGUAGE_ID, strbuf, sizeof(strbuf))) {
    utf16_to_utf8(strbuf, sizeof(strbuf));
    dumpPutAscii((char *)strbuf);
  } else {
    dumpPut("none");
  }
  dumpPutChar('\r');

  dumpPut("Serial ");
  if (desc.iSerialNumber &&
      XFER_RESULT_SUCCESS ==
          tuh_descriptor_get_serial_string_sync(daddr, LANGUAGE_ID, strbuf, sizeof(strbuf))) {
    utf16_to_utf8(strbuf, sizeof(strbuf));
    dumpPutAscii((char *)strbuf);
  } else {
    dumpPut("none");
  }
  dumpPutChar('\r');

  uint8_t const hid_count = tuh_hid_instance_count(daddr);
  dumpPrintf("HID interfaces %u\r", hid_count);
  for (uint8_t i = 0; i < hid_count; i++) {
    uint8_t proto = tuh_hid_interface_protocol(daddr, i);
    dumpPrintf("  HID %u protocol %u = %s\r", i, proto, hid_protocol_name(proto));
  }
}

static void dump_usb_inventory() {
  dumpClear();
  dumpPut("\r=== USB inventory Pico In ===\r");
  dumpPrintf("ACK mismatches: %lu\r", (unsigned long)ackMismatchCount);
  dumpPrintf("ACK timeouts: %lu\r", (unsigned long)ackTimeoutCount);

  uint8_t found = 0;
  for (uint8_t daddr = 1; daddr <= CFG_TUH_DEVICE_MAX; daddr++) {
    USBHost.task();
    if (!tuh_mounted(daddr)) {
      continue;
    }
    found++;
    dump_one_device(daddr);
  }

  if (found == 0) {
    dumpPut("No mounted USB devices.\r");
  } else {
    dumpPrintf("Total mounted addresses: %u\r", found);
  }
  dumpPut("=== end inventory ===\r\r");

  dumpPlay();
}

//--------------------------------------------------------------------+
// Keyboard -> UART (with ACK)
//--------------------------------------------------------------------+
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
      uartSendWithAck(ch);
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

  USBHost.begin(0);
}

void loop() {
  USBHost.task();

  bool left = digitalRead(BTN_LEFT) == LOW;
  bool right = digitalRead(BTN_RIGHT) == LOW;

  digitalWrite(LED_LEFT, left ? HIGH : LOW);
  digitalWrite(LED_RIGHT, right ? HIGH : LOW);

  if (left && !leftPrev) {
    uartSendWithAck('A');
  }
  if (right && !rightPrev) {
    dump_usb_inventory();
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
