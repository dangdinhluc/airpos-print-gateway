# AirPOS Ubuntu Print Gateway

Gateway chạy nền trên Ubuntu 22.04/24.04 x64 và mở giao diện tại
`http://127.0.0.1:20128`. Người dùng chỉ đăng nhập tài khoản quán; cấu hình
control plane được đóng trong binary release, không có form Supabase.

## Cài đặt một lệnh

```bash
curl -fsSL https://raw.githubusercontent.com/dangdinhluc/airpos-print-gateway/main/packaging/install.sh | bash
```

Installer kiểm tra Ubuntu x86_64, CUPS và systemd, tải `.deb` cùng
`SHA256SUMS` từ GitHub Release mới nhất, cài/nâng cấp service và mở browser
nếu máy có desktop session. Nếu không có desktop, mở thủ công:

`http://127.0.0.1:20128`

Service chạy dưới user `airpos-gateway`, thuộc nhóm `lp` và `lpadmin`. USB
được kết nối qua CUPS (`lpinfo`, `lpstat`, `lp`, `lpadmin`); gateway không mở
`/dev/usb/lp*` và không chạy `pkexec`. Queue/device URI phải là giá trị CUPS
đã dò trên chính máy đó.

## Phát triển và build

```bash
cd core
dart pub get
dart analyze lib bin test
dart test

cd ../web
npm ci
npm run check
npm run build
```

Build `.deb` cần Dart, Node.js, `dpkg-deb` và hai biến chỉ được truyền ở máy
build/CI:

```bash
export AIRPOS_SUPABASE_URL='https://your-project.supabase.co'
export AIRPOS_SUPABASE_ANON_KEY='build-time-anon-key'
./packaging/build-deb.sh 2.0.0
```

Artifact release được tạo bởi `.github/workflows/print-gateway-release.yml`
khi push tag dạng `print-gateway-v2.0.0`:

- `airpos-print-gateway_amd64.deb`
- `SHA256SUMS`

Config gateway và printer profile nằm tại `/var/lib/airpos-print-gateway`,
được giữ nguyên khi service restart, rút/cắm USB hoặc reboot. Password chỉ
đi qua request login; access token chỉ ở memory trong lúc provision; gateway
token không được trả qua API browser.

## Kiểm thử phần cứng

Trước khi phát hành cần kiểm tra Ubuntu 22.04 và 24.04 x64 với ESC/POS USB và
Star mC-Print3 USB: receipt, kitchen, QR, cut, cash drawer, rút/cắm USB,
reboot, CUPS dừng, thiếu driver và mất mạng. Worker chỉ ack `printed` sau khi
CUPS báo request đã completed; nhận file thành công hoặc timeout không được
coi là in thành công.
