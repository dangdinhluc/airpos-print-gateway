#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")/.." && pwd)
version=${1:-2.0.0}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

: "${AIRPOS_SUPABASE_URL:?Set AIRPOS_SUPABASE_URL in the release environment}"
: "${AIRPOS_SUPABASE_ANON_KEY:?Set AIRPOS_SUPABASE_ANON_KEY in the release environment}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+~-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid Debian package version: $version" >&2
  exit 1
fi
for command_name in dart npm dpkg-deb; do
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required to build the gateway package." >&2
    exit 1
  }
done

cd "$script_dir"
(cd web && npm ci && npm run build)
(cd core && dart pub get)
install -d build
dart_args=(
  compile exe core/bin/airpos_print_gatewayd.dart
  "-D AIRPOS_SUPABASE_URL=$AIRPOS_SUPABASE_URL"
  "-D AIRPOS_SUPABASE_ANON_KEY=$AIRPOS_SUPABASE_ANON_KEY"
  "-D AIRPOS_GATEWAY_APP_VERSION=ubuntu-$version"
  -o build/airpos_print_gatewayd
)
dart "${dart_args[@]}"

install -d "$stage/DEBIAN"
install -d "$stage/opt/airpos-print-gateway/web"
install -d "$stage/etc/systemd/system"
cp -a web/dist/. "$stage/opt/airpos-print-gateway/web/"
install -m 0755 build/airpos_print_gatewayd \
  "$stage/opt/airpos-print-gateway/airpos_print_gatewayd"
install -m 0644 packaging/airpos-print-gateway.service \
  "$stage/etc/systemd/system/airpos-print-gateway.service"
sed "s/@VERSION@/$version/g" packaging/control > "$stage/DEBIAN/control"
install -m 0755 packaging/postinst "$stage/DEBIAN/postinst"
install -m 0755 packaging/prerm "$stage/DEBIAN/prerm"
install -m 0755 packaging/postrm "$stage/DEBIAN/postrm"

mkdir -p dist
package="dist/airpos-print-gateway_${version}_amd64.deb"
dpkg-deb --build --root-owner-group "$stage" "$package"
echo "Built $package"
