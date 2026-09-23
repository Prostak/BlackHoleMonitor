// PicoIn (v3): USB Host keyboard+mouse -> framed UART HID reports
// Boot HID plus generic HID (Apple Extended 05ac:020b keys; Logitech receiver mouse).
// UART A (LED15): Serial2 GP8 (TX) / GP9 (RX) @ 115200
// UART B (LED16): Serial1 GP0 (TX) / GP1 (RX) @ 115200
//
// Frame In->Out: [0xAA][0x55][TYPE][PAYLOAD...][CHK]
//   TYPE 0x01 keyboard: 8-byte boot report
//   TYPE 0x02 mouse:    4-byte buttons,dx,dy,wheel
//   CHK = XOR of 0x55, TYPE, and payload (not 0xAA)
// Out->In: byte 0x01 = one credit per UART. Dual route waits for both Outs.
// Credit cap matches Out window so idle retransmits do not pile up.
// No credit: coalesce mouse (sum dx/dy/wheel, latest buttons); queue keys.
// USB callback only queues a frame; loop() writes UART so IN stays armed.
//
// Route select (sticky):
//   GP14 -> LED15 on, LED16 off  -> only Serial2
//   GP17 -> LED16 on, LED15 off  -> only Serial1
//   both -> both LEDs on (chordLatched) -> Serial1+Serial2
//   while chordLatched and any held: stay dual; clear latch when both released
//   dual selection stays on LEDs until next press
//   when an LED turns off: send idle kbd+mouse on that UART (no stuck keys)
//   startup: Serial2 + LED15 on
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
static const uint8_t FRAME_SYNC2 = 0x55;
static const uint8_t TYPE_KEYBOARD = 0x01;
static const uint8_t TYPE_MOUSE = 0x02;
static const uint8_t READY_BYTE = 0x01;
static const uint8_t CREDIT_CAP = 2;

const int BTN_LEFT = 14;
const int BTN_RIGHT = 17;
const int LED_LEFT = 15;   // LED15 <-> Serial2
const int LED_RIGHT = 16;  // LED16 <-> Serial1

static bool led15On = false;
static bool led16On = false;
static bool chordLatched = false;
static bool btnLeftPrev = false;
static bool btnRightPrev = false;
static uint8_t pendingMouseAddr = 0;
static uint8_t pendingMouseInst = 0xFF;

static const uint8_t KBD_IDLE[8] = {0};
static const uint8_t MOUSE_IDLE[4] = {0};

static void writeFrameTo(Stream &port, uint8_t type, const uint8_t *payload, uint8_t len) {
  uint8_t chk = (uint8_t)(FRAME_SYNC2 ^ type);
  port.write(FRAME_SYNC);
  port.write(FRAME_SYNC2);
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

static int8_t sat8(int32_t v) {
  if (v > 127) {
    return 127;
  }
  if (v < -128) {
    return -128;
  }
  return (int8_t)v;
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

#define FRAME_Q 32
static const uint32_t KBD_REFRESH_MS = 15;
static uint8_t qType[FRAME_Q];
static uint8_t qLen[FRAME_Q];
static uint8_t qData[FRAME_Q][8];
static uint8_t qHead = 0;
static uint8_t qTail = 0;
static uint8_t qCount = 0;
static uint8_t lastKbd[8] = {0};
static bool haveLastKbd = false;
static uint32_t lastKbdSendMs = 0;
static uint8_t pendMouse[4] = {0};
static bool havePendMouse = false;
static uint8_t credit1 = 0;
static uint8_t credit2 = 0;

static void emitFrame(uint8_t type, const uint8_t *payload, uint8_t len);

static void takeCredits() {
  while (Serial2.available()) {
    if ((uint8_t)Serial2.read() == READY_BYTE && credit2 < CREDIT_CAP) {
      credit2++;
    }
  }
  while (Serial1.available()) {
    if ((uint8_t)Serial1.read() == READY_BYTE && credit1 < CREDIT_CAP) {
      credit1++;
    }
  }
}

static bool canEmit() {
  if (!led15On && !led16On) {
    return false;
  }
  if (led15On && credit2 == 0) {
    return false;
  }
  if (led16On && credit1 == 0) {
    return false;
  }
  return true;
}

static void consumeEmit() {
  if (led15On && credit2 > 0) {
    credit2--;
  }
  if (led16On && credit1 > 0) {
    credit1--;
  }
}

static void qPushKbd(const uint8_t *payload, uint8_t len) {
  if (qCount >= FRAME_Q) {
    return;
  }
  qType[qHead] = TYPE_KEYBOARD;
  qLen[qHead] = len;
  memcpy(qData[qHead], payload, len);
  qHead = (uint8_t)((qHead + 1) % FRAME_Q);
  qCount++;
}

static void sendFrame(uint8_t type, const uint8_t *payload, uint8_t len) {
  if (type == TYPE_MOUSE) {
    if (len > 4) {
      len = 4;
    }
    if (!havePendMouse) {
      memset(pendMouse, 0, 4);
      memcpy(pendMouse, payload, len);
      havePendMouse = true;
    } else {
      pendMouse[0] = payload[0];
      pendMouse[1] = (uint8_t)sat8((int16_t)(int8_t)pendMouse[1] +
                                   (int16_t)(int8_t)payload[1]);
      pendMouse[2] = (uint8_t)sat8((int16_t)(int8_t)pendMouse[2] +
                                   (int16_t)(int8_t)payload[2]);
      pendMouse[3] = (uint8_t)sat8((int16_t)(int8_t)pendMouse[3] +
                                   (int16_t)(int8_t)payload[3]);
    }
    return;
  }
  if (len > 8) {
    len = 8;
  }
  memcpy(lastKbd, payload, 8);
  if (len < 8) {
    memset(lastKbd + len, 0, 8 - len);
  }
  haveLastKbd = true;
  qPushKbd(payload, len);
}

static void emitFrame(uint8_t type, const uint8_t *payload, uint8_t len) {
  if (led15On) {
    writeFrameTo(Serial2, type, payload, len);
  }
  if (led16On) {
    writeFrameTo(Serial1, type, payload, len);
  }
  consumeEmit();
}

static void drainFrameQueue() {
  takeCredits();
  while (qCount > 0 && canEmit()) {
    uint8_t type = qType[qTail];
    uint8_t len = qLen[qTail];
    uint8_t payload[8];
    memcpy(payload, qData[qTail], len);
    qTail = (uint8_t)((qTail + 1) % FRAME_Q);
    qCount--;
    emitFrame(type, payload, len);
    lastKbdSendMs = millis();
  }
  if (havePendMouse && canEmit()) {
    emitFrame(TYPE_MOUSE, pendMouse, 4);
    havePendMouse = false;
  }
}

#define MAX_HID_REPORTS 4
#define MAX_HID_SLOTS 12

// Arduino IDE hoists prototypes; keep this type out of function signatures.
static uint8_t hidDaddr[MAX_HID_SLOTS];
static uint8_t hidInstance[MAX_HID_SLOTS];
static uint8_t hidReportCount[MAX_HID_SLOTS];
static uint8_t hidFallbackKind[MAX_HID_SLOTS];
static uint8_t hidSkipKbd[MAX_HID_SLOTS];
static uint8_t hidHasReportId[MAX_HID_SLOTS];
static uint8_t hidMouseAxis16[MAX_HID_SLOTS];
static tuh_hid_report_info_t hidReportInfo[MAX_HID_SLOTS][MAX_HID_REPORTS];

static int hidSlotFind(uint8_t daddr, uint8_t instance, bool alloc) {
  for (uint8_t i = 0; i < MAX_HID_SLOTS; i++) {
    if (hidDaddr[i] == daddr && hidInstance[i] == instance) {
      return i;
    }
  }
  if (!alloc) {
    return -1;
  }
  for (uint8_t i = 0; i < MAX_HID_SLOTS; i++) {
    if (hidDaddr[i] == 0) {
      hidDaddr[i] = daddr;
      hidInstance[i] = instance;
      hidReportCount[i] = 0;
      hidFallbackKind[i] = 0;
      hidSkipKbd[i] = 0;
      hidHasReportId[i] = 0;
      hidMouseAxis16[i] = 0;
      return i;
    }
  }
  return -1;
}

static void sendKeyboardReport(const uint8_t *report8) {
  sendFrame(TYPE_KEYBOARD, report8, 8);
}

static void hidScanDescFlags(const uint8_t *d, uint16_t n, uint8_t *hasId,
                             uint8_t *has16) {
  *hasId = 0;
  *has16 = 0;
  while (n) {
    uint8_t h = *d++;
    n--;
    if (h == 0xFE) {
      if (n < 2) {
        break;
      }
      uint8_t sz = d[0];
      uint8_t skip = (uint8_t)(2 + sz);
      if (n < skip) {
        break;
      }
      d += skip;
      n -= skip;
      continue;
    }
    uint8_t size = h & 3;
    if (size == 3) {
      size = 4;
    }
    if (n < size) {
      break;
    }
    if ((h & 0xFC) == 0x84) {
      *hasId = 1;
    }
    if (h == 0x75 && size >= 1 && d[0] == 16) {
      *has16 = 1;
    }
    d += size;
    n -= size;
  }
}

static void sendMouseBytes(const uint8_t *p, uint16_t n, bool axis16) {
  uint8_t payload[4] = {0, 0, 0, 0};
  if (n >= 1) {
    payload[0] = p[0];
  }
  if (axis16 && n >= 5) {
    int16_t dx = (int16_t)((uint16_t)p[1] | ((uint16_t)p[2] << 8));
    int16_t dy = (int16_t)((uint16_t)p[3] | ((uint16_t)p[4] << 8));
    payload[1] = (uint8_t)sat8(dx);
    payload[2] = (uint8_t)sat8(dy);
    if (n >= 6) {
      payload[3] = p[5];
    }
  } else {
    if (n >= 2) {
      payload[1] = p[1];
    }
    if (n >= 3) {
      payload[2] = p[2];
    }
    if (n >= 4) {
      payload[3] = p[3];
    }
  }
  sendFrame(TYPE_MOUSE, payload, 4);
}

static void sendMouseReport(const uint8_t *report, uint16_t len, int slot) {
  // C539 report proto (Debug dump): n=9
  // 02 | buttons | pad | x16le | y16le | wheel | pan
  // Require n>=9 and a C539 slot. Right button is also 0x02 — a boot
  // packet [02, dx, dy, ...] must stay boot, or the cursor jumps.
  if (slot >= 0 && hidSkipKbd[slot] && len >= 9 && report[0] == 0x02) {
    uint8_t payload[4] = {0, 0, 0, 0};
    payload[0] = (uint8_t)(report[1] & 0x07);
    int16_t dx =
        (int16_t)((uint16_t)report[3] | ((uint16_t)report[4] << 8));
    int16_t dy =
        (int16_t)((uint16_t)report[5] | ((uint16_t)report[6] << 8));
    payload[1] = (uint8_t)sat8(dx);
    payload[2] = (uint8_t)sat8(dy);
    payload[3] = report[7];
    sendFrame(TYPE_MOUSE, payload, 4);
    return;
  }

  sendMouseBytes(report, len, false);
}

static void sendKeyboardFlexible(const uint8_t *report, uint16_t len) {
  if (len >= 9 && report[0] >= 1 && report[0] <= 15) {
    report++;
    len--;
  }
  if (len >= 8) {
    sendKeyboardReport(report);
  }
}

static void processGenericReport(uint8_t daddr, uint8_t instance,
                                uint8_t const *report, uint16_t len) {
  int slot = hidSlotFind(daddr, instance, false);
  if (slot < 0 || len == 0) {
    return;
  }

  tuh_hid_report_info_t *info = NULL;
  uint8_t const *payload = report;
  uint16_t n = len;

  if (hidReportCount[slot] == 1 && hidReportInfo[slot][0].report_id == 0) {
    info = &hidReportInfo[slot][0];
  } else if (hidReportCount[slot] > 0) {
    uint8_t const rpt_id = report[0];
    for (uint8_t i = 0; i < hidReportCount[slot]; i++) {
      if (hidReportInfo[slot][i].report_id == rpt_id) {
        info = &hidReportInfo[slot][i];
        payload++;
        n--;
        break;
      }
    }
  }

  uint8_t kind = hidFallbackKind[slot];
  if (info && info->usage_page == HID_USAGE_PAGE_DESKTOP) {
    if (info->usage == HID_USAGE_DESKTOP_KEYBOARD) {
      kind = 1;
    } else if (info->usage == HID_USAGE_DESKTOP_MOUSE) {
      kind = 2;
    } else {
      kind = 0;
    }
  } else if (info && info->usage_page == HID_USAGE_PAGE_CONSUMER) {
    kind = 0;
  }

  if (kind == 1 && hidSkipKbd[slot]) {
    kind = 0;
  }
  if (kind == 1) {
    sendKeyboardFlexible(payload, n);
  } else if (kind == 2) {
    sendMouseBytes(payload, n, slot >= 0 && hidMouseAxis16[slot] && n >= 6);
  }
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

  applyLedState(true, false);

  USBHost.begin(0);
}

void loop() {
  USBHost.task();
  drainFrameQueue();
  takeCredits();
  if (haveLastKbd && canEmit() &&
      (millis() - lastKbdSendMs) >= KBD_REFRESH_MS) {
    emitFrame(TYPE_KEYBOARD, lastKbd, 8);
    lastKbdSendMs = millis();
  }
  updateRouteButtons();
  if (pendingMouseInst != 0xFF) {
    uint8_t addr = pendingMouseAddr;
    uint8_t inst = pendingMouseInst;
    pendingMouseInst = 0xFF;
    tuh_hid_set_protocol(addr, inst, HID_PROTOCOL_REPORT);
  }
}

void tuh_hid_mount_cb(uint8_t dev_addr, uint8_t instance,
                      uint8_t const *desc_report, uint16_t desc_len) {
  uint8_t const proto = tuh_hid_interface_protocol(dev_addr, instance);
  int slot = hidSlotFind(dev_addr, instance, true);
  uint16_t vid = 0, pid = 0;
  tuh_vid_pid_get(dev_addr, &vid, &pid);

  if (slot >= 0 && desc_report && desc_len) {
    uint8_t hasId = 0, has16 = 0;
    hidScanDescFlags(desc_report, desc_len, &hasId, &has16);
    hidHasReportId[slot] = hasId;
    hidMouseAxis16[slot] = has16;
    hidReportCount[slot] = tuh_hid_parse_report_descriptor(
        hidReportInfo[slot], MAX_HID_REPORTS, desc_report, desc_len);
  }
  if (slot >= 0 && vid == 0x046d && pid == 0xc539) {
    hidSkipKbd[slot] = 1;
    if (proto == HID_ITF_PROTOCOL_MOUSE) {
      hidHasReportId[slot] = 1;
    }
  }
  if (slot >= 0 && proto == HID_ITF_PROTOCOL_NONE) {
    if (vid == 0x05ac && pid == 0x020b && instance == 0) {
      hidFallbackKind[slot] = 1;
    }
  }

  if (proto == HID_ITF_PROTOCOL_MOUSE) {
    pendingMouseAddr = dev_addr;
    pendingMouseInst = instance;
  }
  tuh_hid_receive_report(dev_addr, instance);
}

void tuh_hid_umount_cb(uint8_t dev_addr, uint8_t instance) {
  if (pendingMouseAddr == dev_addr && pendingMouseInst == instance) {
    pendingMouseInst = 0xFF;
  }
  int slot = hidSlotFind(dev_addr, instance, false);
  if (slot >= 0) {
    hidDaddr[slot] = 0;
    hidInstance[slot] = 0;
    hidReportCount[slot] = 0;
    hidFallbackKind[slot] = 0;
    hidSkipKbd[slot] = 0;
    hidHasReportId[slot] = 0;
    hidMouseAxis16[slot] = 0;
  }
}

void tuh_hid_report_received_cb(uint8_t dev_addr, uint8_t instance,
                                uint8_t const *report, uint16_t len) {
  uint8_t const proto = tuh_hid_interface_protocol(dev_addr, instance);
  uint16_t vid = 0, pid = 0;
  tuh_vid_pid_get(dev_addr, &vid, &pid);
  const bool c539 = (vid == 0x046d && pid == 0xc539);

  if (proto == HID_ITF_PROTOCOL_KEYBOARD && len >= 8) {
    if (!c539) {
      sendKeyboardFlexible(report, len);
    }
  } else if (proto == HID_ITF_PROTOCOL_MOUSE && len >= 3) {
    sendMouseReport(report, len, hidSlotFind(dev_addr, instance, false));
  } else if (proto == HID_ITF_PROTOCOL_NONE && !c539) {
    processGenericReport(dev_addr, instance, report, len);
  }

  tuh_hid_receive_report(dev_addr, instance);
}
