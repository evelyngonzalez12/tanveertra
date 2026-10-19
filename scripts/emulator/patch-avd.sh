#!/usr/bin/env bash
# Runs after the AVD is created and before QEMU boots.
# Rewrites the virtual panel to Galaxy S24 Ultra factory FHD+ (1080x2340 @ 420dpi).
set -euo pipefail
AVD_NAME="${AVD_NAME:-samsung-s24u}"
AVD_DIR="${HOME}/.android/avd/${AVD_NAME}.avd"
CONFIG="${AVD_DIR}/config.ini"
if [[ ! -f "$CONFIG" ]]; then
  echo "AVD config not found at ${CONFIG}" >&2
  ls -la "${HOME}/.android/avd" >&2 || true
  exit 1
fi
set_ini() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$CONFIG"; then
    sed -i -E "s|^${key}=.*|${key}=${val}|" "$CONFIG"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CONFIG"
  fi
}
# S24 Ultra ships FHD+ by default (QHD+ is optional in settings).
set_ini hw.lcd.width 1080
set_ini hw.lcd.height 2340
set_ini hw.lcd.depth 16
set_ini hw.lcd.density 420
set_ini hw.gpu.enabled yes
set_ini hw.gpu.mode swiftshader_indirect
set_ini hw.ramSize 4096
set_ini hw.heapSize 512
set_ini hw.cpu.ncore 4
set_ini hw.mainKeys no
set_ini hw.keyboard no
set_ini hw.dPad no
set_ini hw.trackBall no
set_ini hw.sdCard yes
set_ini hw.accelerometer yes
set_ini hw.gyroscope yes
set_ini hw.gps yes
set_ini hw.gsmModem yes
set_ini hw.sensors.proximity yes
set_ini hw.sensors.magnetic_field yes
set_ini hw.sensors.orientation yes
set_ini hw.battery yes
set_ini hw.audioInput yes
set_ini hw.audioOutput yes
set_ini hw.camera.back emulated
set_ini hw.camera.front emulated
set_ini hw.device.name "Galaxy S24 Ultra"
set_ini hw.device.manufacturer Samsung
set_ini skin.dynamic yes
set_ini showDeviceFrame no
echo "Patched ${CONFIG} to Galaxy S24 Ultra FHD+"
cat "$CONFIG"
