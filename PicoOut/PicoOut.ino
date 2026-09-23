// PicoOut (v3): UART framed HID reports -> USB Keyboard + Mouse
// UART: Serial1 GP0 (TX) / GP1 (RX) @ 115200 <-> PicoIn
//
// Frame In->Out: [0xAA][0x55][TYPE][PAYLOAD...][CHK]
//   TYPE 0x01 keyboard: 8-byte boot report
//   TYPE 0x02 mouse:    4-byte buttons,dx,dy,wheel
//   CHK = XOR of 0x55, TYPE, and payload (not 0xAA)
// Out->In: byte 0x01 = one credit (In may send one more frame).
// Window CREDIT_MAX; refill after a frame is parsed. If no frame arrives
// for CREDIT_REFRESH_MS, retransmit the whole window (lost 0x01 would
// otherwise stall In forever). In caps credits, so extras are ignored.
// 8 ms key-release hold does not stop credits.
//
// Tools -> USB Stack -> Pico SDK

#include <string.h>

#include "Keyboard.h"
#include "Mouse.h"
#include "USB.h"

static const uint8_t FRAME_SYNC = 0xAA;
static const uint8_t FRAME_SYNC2 = 0x55;
static const uint8_t TYPE_KEYBOARD = 0x01;
static const uint8_t TYPE_MOUSE = 0x02;
static const uint8_t READY_BYTE = 0x01;
static const uint8_t CREDIT_MAX = 2;
static const uint8_t KBD_LEN = 8;
static const uint8_t MOUSE_LEN = 4;
static const uint32_t PRESS_HOLD_MS = 8;
static const uint32_t CREDIT_REFRESH_MS = 20;

static uint8_t granted = 0;
static uint32_t lastRxMs = 0;

static void offerCredit() {
  while (granted < CREDIT_MAX) {
    Serial1.write(READY_BYTE);
    granted++;
  }
}

static void consumeCredit() {
  lastRxMs = millis();
  if (granted > 0) {
    granted--;
  }
}

static void refreshCreditsIfIdle() {
  uint32_t now = millis();
  if ((uint32_t)(now - lastRxMs) < CREDIT_REFRESH_MS) {
    return;
  }
  lastRxMs = now;
  for (uint8_t i = 0; i < CREDIT_MAX; i++) {
    Serial1.write(READY_BYTE);
  }
  granted = CREDIT_MAX;
}

enum ParseState : uint8_t {
  WAIT_SYNC,
  WAIT_SYNC2,
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

static uint8_t wantKbd[8] = {0};
static uint8_t sentKbd[8] = {0};
static uint32_t sentKeyAt[6] = {0};

static uint8_t prevMouseButtons = 0;
static uint32_t mouseHoldUntil = 0;
static bool havePendingMouseBtns = false;
static uint8_t pendingMouseBtns = 0;

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

static bool agedSince(uint32_t t0) {
  return (uint32_t)(millis() - t0) >= PRESS_HOLD_MS;
}

static bool mouseHolding() {
  return mouseHoldUntil != 0 && (int32_t)(millis() - mouseHoldUntil) < 0;
}

static void syncKeyboard() {
  uint32_t now = millis();

  for (uint8_t bit = 0; bit < 8; bit++) {
    uint8_t mask = (uint8_t)(1u << bit);
    if ((sentKbd[0] & mask) && !(wantKbd[0] & mask)) {
      Keyboard.release((uint8_t)(128 + bit));
      sentKbd[0] = (uint8_t)(sentKbd[0] & ~mask);
    }
    if ((wantKbd[0] & mask) && !(sentKbd[0] & mask)) {
      Keyboard.press((uint8_t)(128 + bit));
      sentKbd[0] = (uint8_t)(sentKbd[0] | mask);
    }
  }

  for (uint8_t slot = 0; slot < 6; slot++) {
    uint8_t k = sentKbd[slot + 2];
    if (k != 0 && !keyInReport(wantKbd, k) && agedSince(sentKeyAt[slot])) {
      Keyboard.release((uint8_t)(k + 136));
      sentKbd[slot + 2] = 0;
    }
  }

  for (uint8_t i = 2; i < 8; i++) {
    uint8_t k = wantKbd[i];
    if (k == 0 || keyInReport(sentKbd, k)) {
      continue;
    }
    for (uint8_t slot = 0; slot < 6; slot++) {
      if (sentKbd[slot + 2] == 0) {
        Keyboard.press((uint8_t)(k + 136));
        sentKbd[slot + 2] = k;
        sentKeyAt[slot] = now;
        break;
      }
    }
  }
}

static void applyMouseButtonBits(uint8_t buttons, bool *pressed) {
  uint8_t changed = (uint8_t)(buttons ^ prevMouseButtons);
  if (changed & MOUSE_LEFT) {
    if (buttons & MOUSE_LEFT) {
      Mouse.press(MOUSE_LEFT);
      *pressed = true;
    } else {
      Mouse.release(MOUSE_LEFT);
    }
  }
  if (changed & MOUSE_RIGHT) {
    if (buttons & MOUSE_RIGHT) {
      Mouse.press(MOUSE_RIGHT);
      *pressed = true;
    } else {
      Mouse.release(MOUSE_RIGHT);
    }
  }
  if (changed & MOUSE_MIDDLE) {
    if (buttons & MOUSE_MIDDLE) {
      Mouse.press(MOUSE_MIDDLE);
      *pressed = true;
    } else {
      Mouse.release(MOUSE_MIDDLE);
    }
  }
  prevMouseButtons = buttons;
}

static void applyMouseLive(const uint8_t report[4]) {
  uint8_t buttons = (uint8_t)(report[0] & 0x07);
  int8_t dx = (int8_t)report[1];
  int8_t dy = (int8_t)report[2];
  int8_t wheel = (int8_t)report[3];

  if (dx != 0 || dy != 0 || wheel != 0) {
    Mouse.move(dx, dy, wheel);
  }

  uint8_t released = (uint8_t)(prevMouseButtons & ~buttons);
  uint8_t newlyDown = (uint8_t)(buttons & ~prevMouseButtons);

  if (mouseHolding() && released) {
    havePendingMouseBtns = true;
    pendingMouseBtns = buttons;
  } else if (newlyDown || (released && !mouseHolding())) {
    bool pressed = false;
    applyMouseButtonBits(buttons, &pressed);
    havePendingMouseBtns = false;
    if (pressed) {
      yield();
      mouseHoldUntil = millis() + PRESS_HOLD_MS;
    }
  }
}

static void flushPendingMouseButtons() {
  if (mouseHolding() || !havePendingMouseBtns) {
    return;
  }
  bool pressed = false;
  applyMouseButtonBits(pendingMouseBtns, &pressed);
  havePendingMouseBtns = false;
  if (pressed) {
    yield();
    mouseHoldUntil = millis() + PRESS_HOLD_MS;
  }
}

static void parseByte(uint8_t b) {
  switch (state) {
    case WAIT_SYNC:
      if (b == FRAME_SYNC) {
        state = WAIT_SYNC2;
      }
      break;

    case WAIT_SYNC2:
      if (b == FRAME_SYNC2) {
        state = WAIT_TYPE;
      } else if (b != FRAME_SYNC) {
        state = WAIT_SYNC;
      }
      break;

    case WAIT_TYPE:
      frameType = b;
      payloadLen = payloadSizeForType(b);
      if (payloadLen == 0 || payloadLen > sizeof(payload)) {
        state = (b == FRAME_SYNC) ? WAIT_SYNC2 : WAIT_SYNC;
        break;
      }
      chk = (uint8_t)(FRAME_SYNC2 ^ b);
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
      consumeCredit();
      if (b == chk) {
        if (frameType == TYPE_MOUSE && payloadLen == MOUSE_LEN) {
          applyMouseLive(payload);
        } else if (frameType == TYPE_KEYBOARD && payloadLen == KBD_LEN) {
          memcpy(wantKbd, payload, KBD_LEN);
          syncKeyboard();
        }
      }
      state = (b == FRAME_SYNC) ? WAIT_SYNC2 : WAIT_SYNC;
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
  lastRxMs = millis();
  offerCredit();
}

void loop() {
  while (Serial1.available()) {
    parseByte((uint8_t)Serial1.read());
  }
  syncKeyboard();
  flushPendingMouseButtons();
  offerCredit();
  refreshCreditsIfIdle();
}
