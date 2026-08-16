#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./packaging/build-deb.sh <version> [--font <path>] [--star-cputil <path>]

Requires AIRPOS_SUPABASE_URL and AIRPOS_SUPABASE_ANON_KEY in the environment.
The bitmap font source can be passed with --font or AIRPOS_BITMAP_FONT.
The official Star cputil binary can be passed with --star-cputil or STAR_CPUTIL.
EOF
}

app_dir=$(cd -- "$(dirname "$0")/.." && pwd)
font_source=${AIRPOS_BITMAP_FONT:-}
star_cputil=${STAR_CPUTIL:-}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

version=$1
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --font)
      [[ $# -ge 2 ]] || {
        echo "--font requires a path argument." >&2
        exit 1
      }
      font_source=$2
      shift 2
      ;;
    --star-cputil)
      [[ $# -ge 2 ]] || {
        echo "--star-cputil requires a path argument." >&2
        exit 1
      }
      star_cputil=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

: "${AIRPOS_SUPABASE_URL:?Set AIRPOS_SUPABASE_URL in the release environment}"
: "${AIRPOS_SUPABASE_ANON_KEY:?Set AIRPOS_SUPABASE_ANON_KEY in the release environment}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+~-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid Debian package version: $version" >&2
  exit 1
fi
command -v python3 >/dev/null || {
  echo "python3 is required to generate the packaged Unicode font." >&2
  exit 1
}
python3 -c 'import PIL' || {
  echo "python3 Pillow is required to generate the packaged Unicode font." >&2
  exit 1
}
if [[ -z "$font_source" || ! -f "$font_source" ]]; then
  echo "Set AIRPOS_BITMAP_FONT or pass --font with a Noto Sans CJK TTF/TTC font source." >&2
  exit 1
fi
if [[ -z "$star_cputil" || ! -x "$star_cputil" ]]; then
  echo "Set STAR_CPUTIL or pass --star-cputil with the official executable." >&2
  exit 1
fi
for command_name in dart npm dpkg-deb; do
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required to build the gateway package." >&2
    exit 1
  }
done

cd "$app_dir"
(cd web && npm ci && npm run build)
(cd core && dart pub get)
install -d build
dart_args=(
  compile exe core/bin/airpos_print_gatewayd.dart
  "-DAIRPOS_SUPABASE_URL=$AIRPOS_SUPABASE_URL"
  "-DAIRPOS_SUPABASE_ANON_KEY=$AIRPOS_SUPABASE_ANON_KEY"
  "-DAIRPOS_GATEWAY_APP_VERSION=ubuntu-$version"
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
install -d "$stage/opt/airpos-print-gateway/bin"
install -m 0755 "$star_cputil" "$stage/opt/airpos-print-gateway/bin/cputil"
install -d "$stage/opt/airpos-print-gateway/fonts"
python3 packaging/generate_bitmap_font.py \
  --font "$font_source" \
  --output "$stage/opt/airpos-print-gateway/fonts/airpos-unicode.fnt.zip"
python3 packaging/generate_bitmap_font.py \
  --output "$stage/opt/airpos-print-gateway/fonts/airpos-unicode.fnt.zip" \
  --validate-only
sed "s/@VERSION@/$version/g" packaging/control > "$stage/DEBIAN/control"
install -m 0755 packaging/postinst "$stage/DEBIAN/postinst"
install -m 0755 packaging/prerm "$stage/DEBIAN/prerm"
install -m 0755 packaging/postrm "$stage/DEBIAN/postrm"

mkdir -p dist
package="dist/airpos-print-gateway_${version}_amd64.deb"
dpkg-deb --build --root-owner-group "$stage" "$package"
echo "Built $package"
