// Pico Out: UART <-> USB HID keyboard with per-character ACK
// UART: Serial1 GP0 (TX) / GP1 (RX) @ 115200 <-> Pico In Serial2 GP8/GP9
//
// Protocol: In sends a byte; Out types it via HID; when the HID report has been
// handed to the USB host stack, Out echoes the same byte back as ACK.
// This is USB-transfer success, NOT proof that an app displayed the character.
//
// Tools -> USB Stack -> Pico SDK

#include "Keyboard.h"
#include "USB.h"

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
}

void loop() {
  if (!Serial1.available()) {
    return;
  }

  uint8_t c = Serial1.read();

  Keyboard.releaseAll();
  size_t sent = Keyboard.write(c);
  Keyboard.releaseAll();

  // ACK only if Keyboard accepted the keystroke into a HID report.
  // USB host ACK of that report is handled inside write(); we do not get
  // application-level confirmation from macOS.
  if (sent) {
    Serial1.write(c);
    Serial1.flush();
  }
}
