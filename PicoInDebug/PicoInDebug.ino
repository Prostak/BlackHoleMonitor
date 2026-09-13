// PicoInDebug: USB host log -> Serial2 (GP8/GP9) @ 115200
// Pair with PicoOutSimple (not v2). GP17 dumps the log slowly. GP14 clears it.
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

const int BTN_CLEAR = 14;
const int BTN_DUMP = 17;
const int LED_LEFT = 15;
const int LED_RIGHT = 16;

static const uint32_t ACK_TIMEOUT_MS = 300;
static const unsigned PLAYBACK_MS = 18;

static bool btnClearPrev = false;
static bool btnDumpPrev = false;
static uint8_t lastMouseRaw[16];
static uint16_t lastMouseLen = 0;
static uint16_t mouseSeen = 0;
static uint16_t kbdSeen = 0;
static uint16_t genSeen = 0;
static uint16_t mouseLogged = 0;
static uint16_t getRptSeen = 0;

static uint8_t appleAddr = 0;
static uint8_t appleInst0 = 0xFF;
static uint8_t appleInst1 = 0xFF;
static bool appleKickLeds = false;
static uint8_t appleLed = 0x02;  // Caps Lock — visual "Apple HID claimed"
static uint8_t appleGetBuf[16];

#define LOG_SIZE 2800
static char logBuf[LOG_SIZE];
static size_t logHead = 0;
static size_t logCount = 0;

static void logPutChar(char c) {
  logBuf[logHead] = c;
  logHead = (logHead + 1) % LOG_SIZE;
  if (logCount < LOG_SIZE) {
    logCount++;
  }
}

static void logPut(const char *s) {
  if (!s) {
    return;
  }
  while (*s) {
    logPutChar(*s++);
  }
}

static void logPrintf(const char *fmt, ...) {
  char tmp[120];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(tmp, sizeof(tmp), fmt, ap);
  va_end(ap);
  logPut(tmp);
}

static void logLine(const char *fmt, ...) {
  char tmp[140];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(tmp, sizeof(tmp), fmt, ap);
  va_end(ap);
  logPut(tmp);
  logPutChar('\n');
}

static void logHex(const uint8_t *p, uint16_t n, uint8_t maxb) {
  if (n > maxb) {
    n = maxb;
  }
  for (uint16_t i = 0; i < n; i++) {
    logPrintf(" %02x", p[i]);
  }
}

static void logClear() {
  logHead = 0;
  logCount = 0;
  mouseSeen = 0;
  kbdSeen = 0;
  genSeen = 0;
  mouseLogged = 0;
  getRptSeen = 0;
  lastMouseLen = 0;
  logLine("log cleared");
}

static void drainRx() {
  while (Serial2.available()) {
    Serial2.read();
  }
}

static void uartSendWithAck(uint8_t c) {
  drainRx();
  Serial2.write(c);
  Serial2.flush();
  uint32_t start = millis();
  while ((millis() - start) < ACK_TIMEOUT_MS) {
    USBHost.task();
    if (Serial2.available()) {
      Serial2.read();
      delay(PLAYBACK_MS);
      return;
    }
  }
  delay(PLAYBACK_MS);
}

static void dumpSendStr(const char *s) {
  for (; s && *s; s++) {
    uartSendWithAck((uint8_t)*s);
  }
}

static void dumpNowMounted() {
  char line[72];
  snprintf(line, sizeof(line), "now HUB=%u DEV_MAX=%u\n", CFG_TUH_HUB,
           CFG_TUH_DEVICE_MAX);
  dumpSendStr(line);
  uint8_t found = 0;
  uint8_t maxAddr = (uint8_t)(CFG_TUH_DEVICE_MAX + CFG_TUH_HUB);
  for (uint8_t a = 1; a <= maxAddr; a++) {
    if (!tuh_mounted(a)) {
      continue;
    }
    found++;
    uint16_t vid = 0, pid = 0;
    tuh_vid_pid_get(a, &vid, &pid);
    snprintf(line, sizeof(line), "now a%u %04x:%04x\n", a, vid, pid);
    dumpSendStr(line);
  }
  if (!found) {
    dumpSendStr("now empty\n");
  }
}

static void dumpLog() {
  digitalWrite(LED_RIGHT, HIGH);
  uartSendWithAck('\n');
  char summary[80];
  snprintf(summary, sizeof(summary),
           "stats K=%u G=%u M=%u GET=%u apple a%u\n", kbdSeen, genSeen,
           mouseSeen, getRptSeen, appleAddr);
  dumpSendStr(summary);
  dumpNowMounted();
  size_t start = (logCount < LOG_SIZE) ? 0 : logHead;
  for (size_t i = 0; i < logCount; i++) {
    char c = logBuf[(start + i) % LOG_SIZE];
    if (c == '\r') {
      c = '\n';
    }
    if (c == '\n' || (c >= 32 && c <= 126)) {
      uartSendWithAck((uint8_t)c);
    }
  }
  uartSendWithAck('\n');
  digitalWrite(LED_RIGHT, LOW);
}

#define MAX_HID_REPORTS 4
#define MAX_HID_SLOTS 12

static uint8_t hidDaddr[MAX_HID_SLOTS];
static uint8_t hidInstance[MAX_HID_SLOTS];
static uint8_t hidReportCount[MAX_HID_SLOTS];
static uint8_t hidFallbackKind[MAX_HID_SLOTS];
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
      return i;
    }
  }
  return -1;
}

static uint8_t mouseButtonsOf(const uint8_t *r, uint16_t n) {
  if (n >= 2 && r[0] >= 1 && r[0] <= 15) {
    return r[1];
  }
  return (n > 0) ? r[0] : 0;
}

static uint8_t mouseWheelOf(const uint8_t *r, uint16_t n) {
  if (n >= 8 && r[0] >= 1 && r[0] <= 15) {
    return r[7];
  }
  return (n >= 4) ? r[3] : 0;
}

static bool shouldLogMouse(const uint8_t *report, uint16_t len) {
  mouseSeen++;
  uint16_t n = (len > sizeof(lastMouseRaw)) ? sizeof(lastMouseRaw) : len;
  bool btnWheel = false;
  if (lastMouseLen > 0) {
    btnWheel = (mouseButtonsOf(report, n) != mouseButtonsOf(lastMouseRaw, lastMouseLen)) ||
               (mouseWheelOf(report, n) != mouseWheelOf(lastMouseRaw, lastMouseLen));
  }
  bool changed = (n != lastMouseLen);
  if (!changed) {
    for (uint16_t i = 0; i < n; i++) {
      if (report[i] != lastMouseRaw[i]) {
        changed = true;
        break;
      }
    }
  }
  if (!changed) {
    return false;
  }
  // Movement is capped; button/wheel changes always stay in the log.
  if (!btnWheel && mouseLogged >= 8) {
    memcpy(lastMouseRaw, report, n);
    lastMouseLen = n;
    return false;
  }
  memcpy(lastMouseRaw, report, n);
  lastMouseLen = n;
  if (!btnWheel) {
    mouseLogged++;
  }
  return true;
}

void setup() {
  pinMode(BTN_CLEAR, INPUT_PULLUP);
  pinMode(BTN_DUMP, INPUT_PULLUP);
  pinMode(LED_LEFT, OUTPUT);
  pinMode(LED_RIGHT, OUTPUT);
  digitalWrite(LED_LEFT, LOW);
  digitalWrite(LED_RIGHT, LOW);

  Serial2.setTX(8);
  Serial2.setRX(9);
  Serial2.begin(115200);

  USBHost.begin(0);
  logLine("PicoInDebug start");
}

void loop() {
  USBHost.task();

  bool clearBtn = digitalRead(BTN_CLEAR) == LOW;
  bool dumpBtn = digitalRead(BTN_DUMP) == LOW;
  digitalWrite(LED_LEFT, dumpBtn ? HIGH : LOW);

  if (clearBtn && !btnClearPrev) {
    logClear();
  }
  if (dumpBtn && !btnDumpPrev) {
    dumpLog();
  }
  btnClearPrev = clearBtn;
  btnDumpPrev = dumpBtn;

  // Caps Lock lives on the boot keyboard interface (Apple i0 proto=1).
  if (appleAddr && appleInst0 != 0xFF && appleKickLeds) {
    appleKickLeds = false;
    bool ok = tuh_hid_set_report(appleAddr, appleInst0, 0, HID_REPORT_TYPE_OUTPUT,
                                 &appleLed, 1);
    logLine("apple SET_CAPS %s", ok ? "ok" : "fail");
  }
}

void tuh_mount_cb(uint8_t daddr) {
  uint16_t vid = 0, pid = 0;
  tuh_vid_pid_get(daddr, &vid, &pid);
  logLine("+DEV a%u %04x:%04x", daddr, vid, pid);
}

void tuh_umount_cb(uint8_t daddr) {
  logLine("-DEV a%u", daddr);
}

void tuh_hid_mount_cb(uint8_t dev_addr, uint8_t instance,
                      uint8_t const *desc_report, uint16_t desc_len) {
  uint8_t const proto = tuh_hid_interface_protocol(dev_addr, instance);
  uint16_t vid = 0, pid = 0;
  tuh_vid_pid_get(dev_addr, &vid, &pid);
  int slot = hidSlotFind(dev_addr, instance, true);

  logLine("+HID a%u i%u proto=%u %04x:%04x desc=%u", dev_addr, instance, proto,
          vid, pid, desc_len);

  if (slot >= 0 && proto == HID_ITF_PROTOCOL_NONE) {
    hidReportCount[slot] = 0;
    if (desc_report && desc_len) {
      hidReportCount[slot] = tuh_hid_parse_report_descriptor(
          hidReportInfo[slot], MAX_HID_REPORTS, desc_report, desc_len);
    }
    if (vid == 0x05ac && pid == 0x020b && instance == 0) {
      hidFallbackKind[slot] = 1;
    }
    logLine("  parse reports=%u fallback=%u", hidReportCount[slot],
            hidFallbackKind[slot]);
    for (uint8_t i = 0; i < hidReportCount[slot]; i++) {
      logLine("  rpt%u id=%u page=%04x use=%02x", i,
              hidReportInfo[slot][i].report_id, hidReportInfo[slot][i].usage_page,
              hidReportInfo[slot][i].usage);
    }
  }

  if (vid == 0x05ac && pid == 0x020b) {
    appleAddr = dev_addr;
    if (proto == HID_ITF_PROTOCOL_KEYBOARD) {
      appleInst0 = instance;
      appleKickLeds = true;
    } else if (instance == 1) {
      appleInst1 = instance;
    }
  }

  if (proto == HID_ITF_PROTOCOL_MOUSE) {
    tuh_hid_set_protocol(dev_addr, instance, HID_PROTOCOL_REPORT);
    logLine("  set mouse REPORT proto");
  }
  if (!tuh_hid_receive_report(dev_addr, instance)) {
    logLine("  recv FAIL");
  }
}

void tuh_hid_get_report_complete_cb(uint8_t dev_addr, uint8_t idx,
                                    uint8_t report_id, uint8_t report_type,
                                    uint16_t len) {
  getRptSeen++;
  if (len == 0) {
    if (getRptSeen <= 4) {
      logLine("GET a%u i%u stall/err", dev_addr, idx);
    }
    return;
  }
  logPrintf("GET a%u i%u id=%u t=%u n=%u", dev_addr, idx, report_id, report_type,
            len);
  logHex(appleGetBuf, len, 10);
  logPutChar('\n');
}

void tuh_hid_umount_cb(uint8_t dev_addr, uint8_t instance) {
  logLine("-HID a%u i%u", dev_addr, instance);
  if (dev_addr == appleAddr) {
    appleAddr = 0;
    appleInst0 = 0xFF;
    appleInst1 = 0xFF;
  }
  int slot = hidSlotFind(dev_addr, instance, false);
  if (slot >= 0) {
    hidDaddr[slot] = 0;
    hidInstance[slot] = 0;
    hidReportCount[slot] = 0;
    hidFallbackKind[slot] = 0;
  }
}

void tuh_hid_report_received_cb(uint8_t dev_addr, uint8_t instance,
                                uint8_t const *report, uint16_t len) {
  uint8_t const proto = tuh_hid_interface_protocol(dev_addr, instance);
  bool logIt = true;
  char tag = 'R';

  if (proto == HID_ITF_PROTOCOL_KEYBOARD) {
    tag = 'K';
    kbdSeen++;
    logIt = true;
  } else if (proto == HID_ITF_PROTOCOL_MOUSE) {
    tag = 'M';
    logIt = shouldLogMouse(report, len);
  } else {
    tag = 'G';
    genSeen++;
    logIt = true;
  }

  if (logIt) {
    logPrintf("%c a%u i%u p%u n=%u", tag, dev_addr, instance, proto, len);
    logHex(report, len, 16);
    logPutChar('\n');
  }

  tuh_hid_receive_report(dev_addr, instance);
}
