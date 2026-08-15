#!/usr/bin/env bash
set -euo pipefail

release_base='https://github.com/dangdinhluc/airpos-print-gateway/releases/latest/download'
package_name='airpos-print-gateway_amd64.deb'
health_url='http://127.0.0.1:20128/healthz'
install_user=${SUDO_USER:-$(id -un)}
download_dir=$(mktemp -d)
trap 'rm -rf "$download_dir"' EXIT

die() {
  echo "AirPOS gateway install failed: $*" >&2
  exit 1
}

if [ "$(uname -m)" != 'x86_64' ]; then
  die 'only Ubuntu x86_64 is supported.'
fi
if [ ! -r /etc/os-release ]; then
  die 'cannot identify the operating system.'
fi
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = 'ubuntu' ] || die 'only Ubuntu is supported.'
command -v curl >/dev/null || die 'curl is required.'
command -v sha256sum >/dev/null || die 'sha256sum is required.'
command -v dpkg >/dev/null || die 'dpkg is required.'
command -v systemctl >/dev/null || die 'systemd is required.'

root_command=()
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null || die 'sudo is required when not running as root.'
  root_command=(sudo)
fi

if ! command -v lpstat >/dev/null; then
  echo 'CUPS is not installed; installing cups and cups-client...'
  "${root_command[@]}" apt-get update
  "${root_command[@]}" apt-get install -y cups cups-client
fi
"${root_command[@]}" systemctl enable --now cups.service

echo 'Downloading the latest AirPOS print gateway...'
curl --fail --silent --show-error --location \
  "$release_base/$package_name" -o "$download_dir/$package_name"
curl --fail --silent --show-error --location \
  "$release_base/SHA256SUMS" -o "$download_dir/SHA256SUMS"

expected=$(awk -v name="$package_name" '$2 == name { print $1; exit }' "$download_dir/SHA256SUMS")
[ -n "$expected" ] || die 'release checksum does not contain the amd64 package.'
printf '%s  %s\n' "$expected" "$download_dir/$package_name" | sha256sum --check --status - \
  || die 'SHA256 verification failed.'

"${root_command[@]}" dpkg --install "$download_dir/$package_name" \
  || "${root_command[@]}" apt-get install -f -y
"${root_command[@]}" systemctl daemon-reload
"${root_command[@]}" systemctl enable airpos-print-gateway.service
"${root_command[@]}" systemctl restart airpos-print-gateway.service

healthy=false
attempt=0
while [ "$attempt" -lt 30 ]; do
  attempt=$((attempt + 1))
  if curl --fail --silent "$health_url" >/dev/null; then
    healthy=true
    break
  fi
  sleep 1
done
$healthy || {
  "${root_command[@]}" systemctl --no-pager --full status airpos-print-gateway.service || true
  die "gateway did not answer $health_url"
}

echo 'AirPOS Print Gateway is ready.'
echo 'Open http://127.0.0.1:20128 in your browser.'
if command -v xdg-open >/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  if [ "$(id -u)" -eq 0 ] && [ "$install_user" != 'root' ] && command -v runuser >/dev/null; then
    runuser -u "$install_user" -- xdg-open 'http://127.0.0.1:20128/' >/dev/null 2>&1 &
  else
    xdg-open 'http://127.0.0.1:20128/' >/dev/null 2>&1 &
  fi
fi
