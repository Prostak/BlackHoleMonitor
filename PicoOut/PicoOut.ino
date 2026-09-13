// PicoOut (v2): UART framed HID reports -> USB Keyboard + Mouse
// UART: Serial1 GP0 (TX) / GP1 (RX) @ 115200 <- PicoIn Serial2 GP8/GP9
//
// Frame: [0xAA][TYPE][PAYLOAD...][CHK]
//   TYPE 0x01 keyboard: 8-byte boot report
//   TYPE 0x02 mouse:    4-byte buttons,dx,dy,wheel
//   CHK = XOR of TYPE..last payload byte
// No ACK (fire-and-forget).
//
// Tools -> USB Stack -> Pico SDK

#include <string.h>

#include "Keyboard.h"
#include "Mouse.h"
#include "USB.h"

static const uint8_t FRAME_SYNC = 0xAA;
static const uint8_t TYPE_KEYBOARD = 0x01;
static const uint8_t TYPE_MOUSE = 0x02;
static const uint8_t KBD_LEN = 8;
static const uint8_t MOUSE_LEN = 4;

enum ParseState : uint8_t {
  WAIT_SYNC,
  WAIT_TYPE,
  WAIT_PAYLOAD,
  WAIT_CHK
};

static ParseState state = WAIT_SYNC;
static uint8_t frameType = 0;
static uint8_t payloadLen = 0;
static uint8_t payloadIdx = 0;
static uint8_t payload[8];
static uint8_t chk = 0;

static uint8_t prevKbd[8] = {0};
static uint8_t prevMouseButtons = 0;

static uint8_t payloadSizeForType(uint8_t type) {
  if (type == TYPE_KEYBOARD) {
    return KBD_LEN;
  }
  if (type == TYPE_MOUSE) {
    return MOUSE_LEN;
  }
  return 0;
}

static bool keyInReport(const uint8_t report[8], uint8_t key) {
  for (uint8_t i = 2; i < 8; i++) {
    if (report[i] == key) {
      return true;
    }
  }
  return false;
}

static void applyKeyboardReport(const uint8_t report[8]) {
  // Release keys no longer present
  for (uint8_t i = 2; i < 8; i++) {
    uint8_t k = prevKbd[i];
    if (k != 0 && !keyInReport(report, k)) {
      Keyboard.release((uint8_t)(k + 136));
    }
  }
  // Release modifiers cleared
  for (uint8_t bit = 0; bit < 8; bit++) {
    uint8_t mask = (uint8_t)(1u << bit);
    if ((prevKbd[0] & mask) && !(report[0] & mask)) {
      Keyboard.release((uint8_t)(128 + bit));
    }
  }
  // Press new modifiers
  for (uint8_t bit = 0; bit < 8; bit++) {
    uint8_t mask = (uint8_t)(1u << bit);
    if ((report[0] & mask) && !(prevKbd[0] & mask)) {
      Keyboard.press((uint8_t)(128 + bit));
    }
  }
  // Press new keys (HID usage -> Arduino non-printing encoding)
  for (uint8_t i = 2; i < 8; i++) {
    uint8_t k = report[i];
    if (k != 0 && !keyInReport(prevKbd, k)) {
      Keyboard.press((uint8_t)(k + 136));
    }
  }

  memcpy(prevKbd, report, 8);
}

static void applyMouseReport(const uint8_t report[4]) {
  uint8_t buttons = (uint8_t)(report[0] & 0x07);
  int8_t dx = (int8_t)report[1];
  int8_t dy = (int8_t)report[2];
  int8_t wheel = (int8_t)report[3];

  uint8_t changed = (uint8_t)(buttons ^ prevMouseButtons);
  if (changed & MOUSE_LEFT) {
    if (buttons & MOUSE_LEFT) {
      Mouse.press(MOUSE_LEFT);
    } else {
      Mouse.release(MOUSE_LEFT);
    }
  }
  if (changed & MOUSE_RIGHT) {
    if (buttons & MOUSE_RIGHT) {
      Mouse.press(MOUSE_RIGHT);
    } else {
      Mouse.release(MOUSE_RIGHT);
    }
  }
  if (changed & MOUSE_MIDDLE) {
    if (buttons & MOUSE_MIDDLE) {
      Mouse.press(MOUSE_MIDDLE);
    } else {
      Mouse.release(MOUSE_MIDDLE);
    }
  }
  prevMouseButtons = buttons;

  if (dx != 0 || dy != 0 || wheel != 0) {
    Mouse.move(dx, dy, wheel);
  }
}

static void handleFrame() {
  if (frameType == TYPE_KEYBOARD && payloadLen == KBD_LEN) {
    applyKeyboardReport(payload);
  } else if (frameType == TYPE_MOUSE && payloadLen == MOUSE_LEN) {
    applyMouseReport(payload);
  }
}

static void parseByte(uint8_t b) {
  switch (state) {
    case WAIT_SYNC:
      if (b == FRAME_SYNC) {
        state = WAIT_TYPE;
      }
      break;

    case WAIT_TYPE:
      frameType = b;
      payloadLen = payloadSizeForType(b);
      if (payloadLen == 0 || payloadLen > sizeof(payload)) {
        state = WAIT_SYNC;
        break;
      }
      chk = b;
      payloadIdx = 0;
      state = WAIT_PAYLOAD;
      break;

    case WAIT_PAYLOAD:
      payload[payloadIdx++] = b;
      chk ^= b;
      if (payloadIdx >= payloadLen) {
        state = WAIT_CHK;
      }
      break;

    case WAIT_CHK:
      if (b == chk) {
        handleFrame();
      }
      state = WAIT_SYNC;
      break;
  }
}

void UsbNames() {
  USB.disconnect();
  delay(100);
  USB.setVIDPID(0x05ac, 0x020b);
  USB.setManufacturer("Mitsumi Electric");
  USB.setProduct("Apple Extended USB Keyboard");
  USB.connect();
  delay(100);
}

void setup() {
  UsbNames();

  Serial1.setTX(0);
  Serial1.setRX(1);
  Serial1.begin(115200);

  Keyboard.begin();
  Mouse.begin();
}

void loop() {
  while (Serial1.available()) {
    parseByte((uint8_t)Serial1.read());
  }
}
