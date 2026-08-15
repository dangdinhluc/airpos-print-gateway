#!/usr/bin/env bash
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

dropin=/etc/systemd/system/airpos-print-gateway.service.d
install -d -m 0755 "$dropin"
printf '%s\n' '[Unit]' 'Wants=bluetooth.service' 'After=bluetooth.service' > "$dropin/bluetooth.conf"
systemctl daemon-reload
systemctl try-restart airpos-print-gateway.service || true
echo "Bluetooth dependency enabled for the gateway service."
