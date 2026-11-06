type Json = Record<string, unknown>;

type GatewayStatus = {
  configured: boolean;
  worker: { state: string; last_heartbeat_at?: string | null; last_job_count?: number; last_error?: string | null };
};

type Tenant = { tenant_id: string; slug: string; name: string; role: string };
type Health = { status: string; detail?: string | null };
type Capabilities = { cut: boolean; beep: boolean; cash_drawer: boolean; warning?: string | null };
type Printer = {
  id: string;
  name: string;
  connection_type: string;
  protocol: string;
  host?: string | null;
  port: number;
  cups_queue?: string | null;
  cups_device_uri?: string | null;
  printer_model: string;
  role: string;
  area: string;
  station: string;
  paper_width_mm: number;
  cut: boolean;
  beep: boolean;
  cash_drawer: boolean;
  enabled: boolean;
  health?: Health;
  capabilities?: Capabilities;
};
type CupsScan = {
  devices: { transport: string; uri: string; description: string }[];
  queues: { name: string; status: string; disabled: boolean }[];
  models: { name: string; description: string }[];
  default_queue?: string | null;
};
type TemplateSettings = {
  receipt_template: string;
  kitchen_template: string;
  languages: string[];
  show_order_number: boolean;
  show_table: boolean;
  show_date_time: boolean;
  show_staff_name: boolean;
  show_qr_code: boolean;
  show_time_seated: boolean;
};
type PrintProfile = {
  store_name: string;
  store_name_ja: string;
  address: string;
  phone: string;
  tax_id: string;
  currency: string;
  header_text_vi: string;
  header_text_ja: string;
  footer_text_vi: string;
  footer_text_ja: string;
  template_settings: TemplateSettings;
};
type PrintProfileSync = { last_synced_at?: string | null; local_edited_at?: string | null; warning?: string | null };
type PrintProfileResponse = { profile: PrintProfile; sync: PrintProfileSync; font_warning?: string | null };
type PreviewResponse = { type: 'receipt' | 'kitchen'; template: string; paper_width_mm: number; text: string };

const app = document.querySelector<HTMLElement>('#app')!;
const toast = document.querySelector<HTMLElement>('#toast')!;
let gatewayStatus: GatewayStatus | null = null;
let printers: Printer[] = [];
let scan: CupsScan | null = null;
let tenants: Tenant[] = [];
let editing: Printer | null = null;
let printerSetupStep = 0;
let setupTestPassed = false;
let setupScanAttempted = false;
let printProfile: PrintProfileResponse | null = null;
let preview: PreviewResponse | null = null;
let busy = false;
let toastTimer = 0;

class ApiError extends Error {
  constructor(public readonly code: string, message: string, public readonly statusCode: number) {
    super(message);
  }
}

async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(path, {
    ...init,
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...(init.headers ?? {}) },
  });
  const body = (await response.json().catch(() => ({}))) as Json;
  if (!response.ok || body.ok === false) {
    throw new ApiError(String(body.code ?? 'REQUEST_FAILED'), String(body.message ?? 'Không thể hoàn tất yêu cầu.'), response.status);
  }
  return body as T;
}

function esc(value: unknown): string {
  return String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[char] ?? char));
}

function showToast(message: string, error = false): void {
  toast.textContent = message;
  toast.style.background = error ? '#a52f2f' : '#162238';
  toast.classList.add('show');
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => toast.classList.remove('show'), 3600);
}

function setBusy(value: boolean): void {
  busy = value;
  document.querySelectorAll<HTMLButtonElement>('button').forEach((button) => { button.disabled = value; });
}

function friendlyStatus(value: string): string {
  return ({
    connected: 'Đã kết nối',
    'queue-missing': 'Thiếu queue',
    'permission-denied': 'Thiếu quyền',
    'driver-missing': 'Thiếu driver',
    'printer-error': 'Lỗi máy in',
    unavailable: 'Chưa sẵn sàng',
  } as Record<string, string>)[value] ?? value;
}

function dotClass(value: string): string {
  if (value === 'online' || value === 'connected') return 'ok';
  if (value === 'not_configured') return 'warn';
  return 'bad';
}

function renderLogin(error = ''): void {
  app.innerHTML = `<div class="shell"><div class="container narrow"><section class="card login-card">
    <div class="brand"><span class="brand-mark" aria-hidden="true"></span><span>AirPOS Print Gateway</span></div>
    <p class="eyebrow">Thiết lập máy in</p><h1>Đăng nhập tài khoản quán</h1>
    <p class="muted">Gateway chạy nền trên máy Ubuntu này. Đăng nhập để gắn máy với quán của anh.</p>
    ${error ? `<p class="error">${esc(error)}</p>` : ''}
    <form id="login-form" class="form-stack" autocomplete="on">
      <div class="field"><label for="email">Email</label><input id="email" name="email" type="email" autocomplete="username" required /></div>
      <div class="field"><label for="password">Mật khẩu</label><input id="password" name="password" type="password" autocomplete="current-password" required /></div>
      <button class="primary" type="submit">Đăng nhập và kết nối</button>
    </form>
  </section></div></div>`;
  document.querySelector<HTMLFormElement>('#login-form')?.addEventListener('submit', async (event) => {
    event.preventDefault();
    const form = new FormData(event.currentTarget as HTMLFormElement);
    try {
      setBusy(true);
      const result = await api<Json>('/api/auth/login', { method: 'POST', body: JSON.stringify({ email: form.get('email'), password: form.get('password') }) });
      if (result.state === 'choose_tenant') {
        tenants = (result.tenants as Tenant[] | undefined) ?? [];
        renderTenantChoice();
      } else {
        await loadDashboard();
      }
    } catch (error) {
      renderLogin(error instanceof ApiError ? error.message : 'Không kết nối được hệ thống.');
    } finally { setBusy(false); }
  });
}

function renderTenantChoice(error = ''): void {
  app.innerHTML = `<div class="shell"><div class="container narrow"><section class="card login-card">
    <div class="brand"><span class="brand-mark" aria-hidden="true"></span><span>AirPOS Print Gateway</span></div>
    <p class="eyebrow">Chọn quán</p><h1>Gateway sẽ gắn với quán nào?</h1><p class="muted">Chọn một quán để tiếp tục. Mỗi gateway chỉ kết nối một quán tại một thời điểm.</p>
    ${error ? `<p class="error">${esc(error)}</p>` : ''}<div class="tenant-list">${tenants.map((tenant) => `<button class="tenant-option" data-tenant="${esc(tenant.tenant_id)}"><span><span class="tenant-name">${esc(tenant.name)}</span><span class="tenant-meta">${esc(tenant.slug)} · ${esc(tenant.role)}</span></span><span>›</span></button>`).join('')}</div>
    <button class="secondary" id="back-login">Quay lại đăng nhập</button>
  </section></div></div>`;
  document.querySelectorAll<HTMLButtonElement>('[data-tenant]').forEach((button) => button.addEventListener('click', async () => {
    try { setBusy(true); await api('/api/auth/provision', { method: 'POST', body: JSON.stringify({ tenant_id: button.dataset.tenant }) }); await loadDashboard(); }
    catch (error) { renderTenantChoice(error instanceof ApiError ? error.message : 'Không kết nối được hệ thống.'); }
    finally { setBusy(false); }
  }));
  document.querySelector<HTMLButtonElement>('#back-login')?.addEventListener('click', () => renderLogin());
}

async function loadDashboard(): Promise<void> {
  gatewayStatus = await api<GatewayStatus>('/api/status');
  if (!gatewayStatus.configured) { renderLogin(); return; }
  const [profileResult, printerResult] = await Promise.all([
    api<PrintProfileResponse>('/api/print-profile'),
    api<{ printers: Printer[] }>('/api/printers'),
  ]);
  printProfile = profileResult;
  printers = printerResult.printers ?? [];
  renderDashboard();
}

function renderDashboard(): void {
  const worker = gatewayStatus?.worker ?? { state: 'starting' };
  app.innerHTML = `<div class="shell"><header class="topbar"><div class="brand"><span class="brand-mark" aria-hidden="true"></span><span>AirPOS Print Gateway</span></div><div class="top-actions"><span class="subtle">Chỉ truy cập trên máy này</span><button class="ghost" id="logout">Đăng xuất</button></div></header><div class="container">
    <div class="dashboard-head"><div><p class="eyebrow">Gateway Ubuntu</p><h1>Máy in</h1><p class="muted">Thêm máy in, rồi in thử để kiểm tra kết nối.</p></div><div class="actions"><button class="secondary" id="refresh">Làm mới</button><button class="primary" id="new-printer">Thêm máy in</button></div></div>
    <div class="status-grid"><div class="card metric"><span class="metric-label">Gateway</span><div class="metric-value"><span class="dot ${dotClass(worker.state)}"></span>${esc(worker.state === 'online' ? 'Đang chạy' : worker.state === 'not_configured' ? 'Chưa cấu hình' : 'Cần kiểm tra')}</div></div><div class="card metric"><span class="metric-label">Máy in</span><div class="metric-value">${printers.length}</div></div><div class="card metric"><span class="metric-label">Lệnh in gần đây</span><div class="metric-value">${esc(worker.last_job_count ?? 0)}</div></div></div>
    ${worker.last_error ? `<p class="error">${esc(worker.last_error)}</p>` : ''}
    <section class="printer-section"><div class="section-head"><div><p class="eyebrow">Danh sách</p><h2>Máy in đã thêm</h2><p class="subtle">Cấu hình được lưu trên Gateway này.</p></div></div>${renderPrinters()}${editing ? renderEditor(editing) : ''}</section>
    <details class="settings-disclosure"><summary>Cài đặt nâng cao</summary><div class="settings-content">${renderPrintProfile()}<section><div class="section-head"><div><h2>Dò CUPS</h2><p class="subtle">Dùng khi cần kiểm tra thiết bị hoặc cấu hình máy in thủ công.</p></div><button class="secondary" id="scan">Quét CUPS</button></div><div class="card cups-panel">${renderScan()}</div></section></div></details>
  </div></div>`;
  bindDashboardEvents();
}

function renderPrintProfile(): string {
  if (!printProfile) return '<section class="card empty">Không đọc được cấu hình mẫu in local.</section>';
  const { profile, font_warning: fontWarning } = printProfile;
  const settings = profile.template_settings;
  const option = (value: string, label: string, selected: boolean) => `<option value="${esc(value)}" ${selected ? 'selected' : ''}>${esc(label)}</option>`;
  const check = (name: keyof TemplateSettings, label: string) => `<label class="check-row"><input type="checkbox" name="${esc(name)}" ${settings[name] ? 'checked' : ''} /> ${esc(label)}</label>`;
  return `<section class="print-profile-section"><div class="section-head"><div><p class="eyebrow">Mẫu in local</p><h2>Cấu hình nội dung bản in</h2><p class="subtle">Lưu trên gateway này; không thay đổi cấu hình tài khoản trên hệ thống.</p></div><div class="actions"><button class="secondary" id="import-store-profile" type="button">Tải thông tin quán</button><button class="primary" type="submit" form="print-profile-form">Lưu mẫu hóa đơn</button></div></div>${fontWarning ? `<p class="warning">${esc(fontWarning)}</p>` : ''}<form id="print-profile-form" class="profile-grid"><section class="card template-card"><p class="eyebrow">Hóa đơn</p><h3>Mẫu receipt</h3><div class="field"><label for="receipt-template">Kiểu hóa đơn</label><select id="receipt-template" name="receipt_template">${option('modern', 'Modern', settings.receipt_template === 'modern')}${option('classic', 'Classic', settings.receipt_template === 'classic')}${option('compact', 'Compact', settings.receipt_template === 'compact')}${option('detailed', 'Detailed', settings.receipt_template === 'detailed')}</select></div><div class="field"><label for="receipt-languages">Ngôn ngữ hóa đơn</label><select id="receipt-languages" name="languages">${option('vi,ja', 'Tiếng Việt + 日本語', settings.languages.join(',') === 'vi,ja')}${option('ja,vi', '日本語 + Tiếng Việt', settings.languages.join(',') === 'ja,vi')}${option('ja', '日本語 (chỉ tiếng Nhật)', settings.languages.join(',') === 'ja')}${option('vi', 'Tiếng Việt (chỉ tiếng Việt)', settings.languages.join(',') === 'vi')}${option('en', 'English (chỉ tiếng Anh)', settings.languages.join(',') === 'en')}${option('ja,en', '日本語 + English', settings.languages.join(',') === 'ja,en')}${option('vi,en', 'Tiếng Việt + English', settings.languages.join(',') === 'vi,en')}</select></div><div class="grid-2 profile-fields"><div class="field"><label for="store-name">Tên cửa hàng</label><input id="store-name" name="store_name" value="${esc(profile.store_name)}" autocomplete="organization" /></div><div class="field"><label for="store-name-ja">Tên cửa hàng (JA)</label><input id="store-name-ja" name="store_name_ja" value="${esc(profile.store_name_ja)}" /></div><div class="field"><label for="phone">Số điện thoại</label><input id="phone" name="phone" value="${esc(profile.phone)}" autocomplete="tel" /></div><div class="field"><label for="currency">Tiền tệ</label><input id="currency" name="currency" value="${esc(profile.currency)}" maxlength="8" /></div><div class="field"><label for="tax-id">Mã số thuế</label><input id="tax-id" name="tax_id" value="${esc(profile.tax_id)}" maxlength="80" /></div><div class="field full"><label for="address">Địa chỉ</label><textarea id="address" name="address" rows="2">${esc(profile.address)}</textarea></div><div class="field"><label for="header-vi">Header (VI)</label><textarea id="header-vi" name="header_text_vi" rows="2">${esc(profile.header_text_vi)}</textarea></div><div class="field"><label for="header-ja">Header (JA)</label><textarea id="header-ja" name="header_text_ja" rows="2">${esc(profile.header_text_ja)}</textarea></div><div class="field"><label for="footer-vi">Footer (VI)</label><textarea id="footer-vi" name="footer_text_vi" rows="2">${esc(profile.footer_text_vi)}</textarea></div><div class="field"><label for="footer-ja">Footer (JA)</label><textarea id="footer-ja" name="footer_text_ja" rows="2">${esc(profile.footer_text_ja)}</textarea></div></div><fieldset class="check-grid"><legend>Thông tin hiển thị</legend>${check('show_order_number', 'Số đơn hàng')}${check('show_table', 'Bàn')}${check('show_date_time', 'Ngày giờ')}${check('show_staff_name', 'Nhân viên')}${check('show_qr_code', 'QR')}${check('show_time_seated', 'Thời gian ngồi')}</fieldset></section><section class="card template-card"><p class="eyebrow">Bếp</p><h3>Mẫu kitchen</h3><div class="field"><label for="kitchen-template">Kiểu phiếu bếp</label><select id="kitchen-template" name="kitchen_template">${option('standard', 'Standard', settings.kitchen_template === 'standard')}${option('compact', 'Compact', settings.kitchen_template === 'compact')}${option('checklist', 'Checklist', settings.kitchen_template === 'checklist')}</select></div><p class="muted">Mẫu bếp được worker dùng khi xử lý job kitchen local.</p></section></form><section class="card preview-card"><div class="section-head"><div><p class="eyebrow">Kiểm tra</p><h3>Print preview</h3><p class="subtle">Preview dùng cấu hình đã lưu local.</p></div><div class="actions"><label class="field"><span>Khổ giấy</span><select id="preview-paper-width"><option value="80" ${(!preview || preview.paper_width_mm !== 58) ? 'selected' : ''}>80 mm</option><option value="58" ${preview?.paper_width_mm === 58 ? 'selected' : ''}>58 mm</option></select></label><button class="secondary" data-preview="receipt" type="button">Preview receipt</button><button class="secondary" data-preview="kitchen" type="button">Preview kitchen</button></div></div>${preview ? `<p class="subtle">${esc(preview.type)} · ${esc(preview.template)} · ${esc(preview.paper_width_mm)} mm</p><pre id="preview-output" class="preview-output">${esc(preview.text)}</pre>` : '<div class="empty">Chưa có bản xem thử.</div>'}</section></section>`;
}

function renderScan(): string {
  if (!scan) return '<div class="empty">Chưa quét CUPS. Bấm “Quét máy in USB” để lấy queue, device URI và model hợp lệ.</div>';
  const devices = scan.devices.length ? scan.devices.map((item) => `<div class="scan-row"><span>${esc(item.description || item.transport)}</span><code>${esc(item.uri)}</code></div>`).join('') : '<div class="subtle">Không tìm thấy device URI.</div>';
  const queues = scan.queues.length ? scan.queues.map((item) => `<div class="scan-row"><strong>${esc(item.name)}</strong><span>${esc(item.status)}</span></div>`).join('') : '<div class="subtle">Không tìm thấy queue CUPS.</div>';
  return `<div class="scan-output"><h3>Thiết bị (${scan.devices.length})</h3>${devices}<h3>Queue (${scan.queues.length})</h3>${queues}<p class="subtle">${scan.models.length} model/driver được CUPS cung cấp${scan.default_queue ? ` · mặc định: ${esc(scan.default_queue)}` : ''}.</p></div>`;
}

function renderPrinters(): string {
  if (!printers.length) return '<div class="empty empty-state"><strong>Chưa có máy in</strong><span>Thêm máy in để Gateway có thể nhận lệnh in từ quán.</span></div>';
  return `<div class="printer-grid">${printers.map((printer) => {
    const health = printer.health?.status ?? 'unavailable';
    const capabilities = printer.capabilities ?? { cut: false, beep: false, cash_drawer: false };
    const location = printer.connection_type === 'network' ? (printer.host ? `${printer.host}:${printer.port}` : 'Mạng / CUPS') : printer.connection_type === 'bluetooth' ? 'Bluetooth' : 'USB';
    const role = printer.role === 'kitchen' ? 'Phiếu bếp' : printer.role === 'qr' ? 'In mã QR' : printer.role === 'cash_drawer' ? 'Két tiền' : 'Hóa đơn';
    const testAction = printer.role === 'kitchen' ? 'kitchen' : 'receipt';
    return `<article class="card printer-card"><div class="printer-title"><div><h3>${esc(printer.name)}</h3><p class="subtle">${role} · ${esc(location)}</p></div><span class="health ${esc(health)}"><span class="dot ${dotClass(health)}"></span>${esc(friendlyStatus(health))}</span></div><div class="printer-meta"><div>Khổ giấy: <strong>${esc(printer.paper_width_mm)} mm</strong> · ${printer.enabled ? 'Đang bật' : 'Đang tắt'}</div>${printer.health?.detail ? `<div>${esc(printer.health.detail)}</div>` : ''}${capabilities.warning ? `<div class="subtle">${esc(capabilities.warning)}</div>` : ''}</div><div class="printer-primary-actions"><button class="primary" data-test="${testAction}" data-id="${esc(printer.id)}">In thử</button><button class="secondary" data-edit="${esc(printer.id)}">Chỉnh sửa</button></div><details class="printer-tools"><summary>Thao tác khác</summary><div class="test-actions"><button class="secondary mini" data-test="connection" data-id="${esc(printer.id)}">Kiểm tra kết nối</button><button class="secondary mini" data-test="receipt" data-id="${esc(printer.id)}">In thử hóa đơn</button><button class="secondary mini" data-test="kitchen" data-id="${esc(printer.id)}">In thử phiếu bếp</button>${capabilities.cut ? `<button class="secondary mini" data-test="cut" data-id="${esc(printer.id)}">Cắt giấy</button>` : ''}${capabilities.beep ? `<button class="secondary mini" data-test="beep" data-id="${esc(printer.id)}">Bíp</button>` : ''}${capabilities.cash_drawer ? `<button class="secondary mini" data-test="cash_drawer" data-id="${esc(printer.id)}">Mở két tiền</button>` : ''}<button class="danger mini" data-delete="${esc(printer.id)}">Xóa máy in</button></div></details></article>`;
  }).join('')}</div>`;
}

function renderPrinterSetupWizard(printer: Printer): string {
  const devices = scan?.devices.filter((item) => /^(usb|bluetooth):/i.test(item.uri)) ?? [];
  const selectedDevice = devices.find((item) => item.uri === printer.cups_device_uri);
  const step = Math.min(printerSetupStep, 3);
  const progress = `<ol class="setup-progress" aria-label="Các bước thiết lập"><li class="${step >= 1 ? (step === 1 ? 'is-current' : 'is-complete') : ''}" ${step === 1 ? 'aria-current="step"' : ''}>1. Chọn máy</li><li class="${step === 2 ? 'is-current' : step > 2 ? 'is-complete' : ''}" ${step === 2 ? 'aria-current="step"' : ''}>2. Thông tin</li><li class="${step === 3 ? 'is-current' : printerSetupStep > 3 ? 'is-complete' : ''}" ${step === 3 ? 'aria-current="step"' : ''}>3. In thử</li></ol>`;
  const closeLabel = printer.id ? 'Đóng' : 'Hủy';

  if (printerSetupStep === 1) {
    const deviceOptions = devices.map((item) => `<option value="${esc(item.uri)}" ${item.uri === printer.cups_device_uri ? 'selected' : ''}>${esc(item.description || item.uri)}</option>`).join('');
    const emptyMessage = scan ? 'Chưa tìm thấy máy in USB hoặc Bluetooth.' : setupScanAttempted ? 'Không đọc được danh sách thiết bị. Hãy thử quét lại.' : 'Đang tìm thiết bị máy in...';
    return `<section class="card editor setup-wizard" id="printer-setup">${progress}<p class="eyebrow">Bước 1 / 3</p><h2>Chọn máy in</h2><p class="muted">Kết nối máy in USB hoặc Bluetooth với Gateway rồi chọn thiết bị tìm thấy.</p>${devices.length ? `<div class="field"><label for="setup-device">Thiết bị</label><select id="setup-device"><option value="">Chọn máy in</option>${deviceOptions}</select></div>` : `<div class="empty">${emptyMessage}</div>`}${scan && devices.length === 0 ? '<p class="subtle">Nếu anh dùng máy in mạng hoặc Star, chọn “Cấu hình nâng cao”.</p>' : ''}<div class="actions setup-actions"><button class="secondary" id="cancel-wizard">${closeLabel}</button><button class="secondary" id="manual-setup">Cấu hình nâng cao</button><button class="secondary" id="scan-setup">${scan || setupScanAttempted ? 'Quét lại' : 'Quét máy in'}</button><button class="primary" id="setup-next">Tiếp tục</button></div></section>`;
  }

  if (printerSetupStep === 2) {
    return `<section class="card editor setup-wizard" id="printer-setup">${progress}<p class="eyebrow">Bước 2 / 3</p><h2>Đặt tên và chọn loại phiếu</h2><p class="muted">Gateway sẽ tự tạo hàng đợi in cho thiết bị đã chọn.</p><div class="setup-device-summary"><span>Máy in</span><strong>${esc(selectedDevice?.description || selectedDevice?.uri || printer.cups_device_uri)}</strong><button class="secondary mini" id="setup-change-device">Đổi máy</button></div><form id="printer-setup-form" class="form-stack"><div class="field"><label for="setup-name">Tên máy in</label><input id="setup-name" name="name" value="${esc(printer.name)}" placeholder="Ví dụ: Máy in hóa đơn" required /></div><div class="grid-2"><div class="field"><label for="setup-role">Dùng để in</label><select id="setup-role" name="role"><option value="receipt" ${printer.role === 'receipt' ? 'selected' : ''}>Hóa đơn</option><option value="kitchen" ${printer.role === 'kitchen' ? 'selected' : ''}>Phiếu bếp</option></select></div><div class="field"><label for="setup-paper">Khổ giấy</label><select id="setup-paper" name="paper_width_mm"><option value="80" ${printer.paper_width_mm !== 58 ? 'selected' : ''}>80 mm</option><option value="58" ${printer.paper_width_mm === 58 ? 'selected' : ''}>58 mm</option></select></div></div><div class="actions setup-actions"><button class="secondary" id="cancel-wizard" type="button">${closeLabel}</button><button class="secondary" id="setup-back" type="button">Quay lại</button><button class="primary" type="submit">Lưu và tiếp tục</button></div></form></section>`;
  }

  if (printerSetupStep === 3) {
    const printLabel = printer.role === 'kitchen' ? 'phiếu bếp' : 'hóa đơn';
    return `<section class="card editor setup-wizard" id="printer-setup">${progress}<p class="eyebrow">Bước 3 / 3</p><h2>In thử để kiểm tra</h2><p class="muted">Máy in đã được lưu. Bấm nút bên dưới để gửi một ${printLabel} thử.</p><div class="setup-device-summary"><span>${esc(printer.name)}</span><strong>Chưa in thử</strong></div><div class="actions setup-actions"><button class="secondary" id="cancel-wizard">Đóng</button><button class="secondary" id="setup-skip">Để sau</button><button class="primary" id="setup-test">In thử ${printLabel}</button></div></section>`;
  }

  return `<section class="card editor setup-wizard setup-complete" id="printer-setup">${progress}<p class="eyebrow">Thiết lập xong</p><h2>Máy in đã được thêm</h2><p class="muted">${setupTestPassed ? 'Phiếu in thử đã được gửi thành công.' : 'Máy in đã được lưu. Anh có thể in thử sau từ danh sách máy in.'}</p><button class="primary" id="setup-finish">Hoàn tất</button></section>`;
}

function renderEditor(printer: Printer): string {
  if (printerSetupStep > 0) return renderPrinterSetupWizard(printer);
  const option = (value: string, label: string, selected: boolean) => `<option value="${value}" ${selected ? 'selected' : ''}>${label}</option>`;
  const devices = scan?.devices.map((item) => `<option value="${esc(item.uri)}">${esc(item.uri)}</option>`).join('') ?? '';
  const models = scan?.models.map((item) => `<option value="${esc(item.name)}">${esc(item.name)} — ${esc(item.description)}</option>`).join('') ?? '';
  const queues = scan?.queues.map((item) => `<option value="${esc(item.name)}">${esc(item.name)}</option>`).join('') ?? '';
  const hasAdvancedValue = Boolean(printer.cups_queue || printer.cups_device_uri || printer.host || (printer.printer_model && printer.printer_model !== 'raw'));
  return `<section class="card editor" id="editor"><div class="section-head"><div><h2>${printer.id ? 'Sửa printer profile' : 'Thêm printer profile'}</h2><p class="subtle">Queue và driver chỉ được server chấp nhận nếu CUPS xác nhận.</p></div><button class="secondary" id="cancel-editor">Đóng</button></div><form id="printer-form" class="form-stack" data-id="${esc(printer.id)}"><div class="grid-2"><div class="field"><label for="p-name">Tên hiển thị</label><input id="p-name" name="name" value="${esc(printer.name)}" required /></div><div class="field"><label for="p-role">Vai trò</label><select id="p-role" name="role">${option('receipt', 'Receipt', printer.role === 'receipt')}${option('kitchen', 'Kitchen', printer.role === 'kitchen')}${option('qr', 'QR', printer.role === 'qr')}${option('cash_drawer', 'Két tiền', printer.role === 'cash_drawer')}</select></div></div><div class="grid-3"><div class="field"><label for="p-connection">Kết nối</label><select id="p-connection" name="connection_type">${option('usb', 'USB / CUPS', printer.connection_type === 'usb')}${option('network', 'Mạng TCP', printer.connection_type === 'network')}${option('bluetooth', 'Bluetooth / CUPS', printer.connection_type === 'bluetooth')}</select></div><div class="field"><label for="p-protocol">Protocol</label><select id="p-protocol" name="protocol">${option('escpos', 'ESC/POS raw', printer.protocol === 'escpos')}${option('star_cups', 'Star CUPS', printer.protocol === 'star_cups')}</select></div><div class="field"><label for="p-paper">Khổ giấy</label><select id="p-paper" name="paper_width_mm">${option('80', '80 mm', printer.paper_width_mm !== 58)}${option('58', '58 mm', printer.paper_width_mm === 58)}</select></div></div><details class="advanced-fields" ${hasAdvancedValue ? 'open' : ''}><summary>Thiết lập nâng cao: queue, URI, model và host</summary><div class="form-stack"><div class="grid-2"><div class="field"><label for="p-queue">CUPS queue</label><input id="p-queue" name="cups_queue" list="queue-list" value="${esc(printer.cups_queue ?? '')}" placeholder="receipt_usb" /><datalist id="queue-list">${queues}</datalist></div><div class="field"><label for="p-uri">Device URI</label><input id="p-uri" name="cups_device_uri" list="device-list" value="${esc(printer.cups_device_uri ?? '')}" placeholder="usb://..." /><datalist id="device-list">${devices}</datalist></div></div><div class="grid-2"><div class="field"><label for="p-model">CUPS model/driver</label><input id="p-model" name="printer_model" list="model-list" value="${esc(printer.printer_model)}" placeholder="raw hoặc model từ lpinfo -m" /><datalist id="model-list">${models}</datalist></div><div class="field"><label for="p-host">Host mạng (nếu dùng TCP)</label><input id="p-host" name="host" value="${esc(printer.host ?? '')}" placeholder="192.168.1.20" /></div></div></div></details><div class="grid-3"><div class="field"><label for="p-area">Area</label><input id="p-area" name="area" value="${esc(printer.area)}" /></div><div class="field"><label for="p-station">Station</label><input id="p-station" name="station" value="${esc(printer.station)}" /></div><div class="field"><label for="p-port">Port</label><input id="p-port" name="port" type="number" min="1" max="65535" value="${esc(printer.port)}" /></div></div><div class="grid-3"><label class="check-row"><input type="checkbox" name="cut" ${printer.cut ? 'checked' : ''} /> Cut</label><label class="check-row"><input type="checkbox" name="beep" ${printer.beep ? 'checked' : ''} /> Beep</label><label class="check-row"><input type="checkbox" name="cash_drawer" ${printer.cash_drawer ? 'checked' : ''} /> Cash drawer</label></div><div class="actions right"><button class="primary" type="submit">Lưu profile</button><button class="secondary" type="button" id="setup-queue" ${printer.id ? '' : 'disabled'}>Tạo/cập nhật queue</button></div></form></section>`;
}

function bindDashboardEvents(): void {
  document.querySelector<HTMLButtonElement>('#logout')?.addEventListener('click', async () => { await api('/api/auth/logout', { method: 'POST', body: '{}' }).catch(() => undefined); gatewayStatus = null; renderLogin(); });
  document.querySelector<HTMLButtonElement>('#refresh')?.addEventListener('click', () => void run(loadDashboard));
  document.querySelector<HTMLButtonElement>('#new-printer')?.addEventListener('click', startPrinterSetup);
  document.querySelector<HTMLButtonElement>('#scan')?.addEventListener('click', () => void run(async () => { const result = await api<CupsScan & { ok: boolean }>('/api/cups/scan', { method: 'POST', body: '{}' }); scan = result; renderDashboard(); document.querySelector<HTMLDetailsElement>('.settings-disclosure')?.setAttribute('open', ''); showToast('Đã quét CUPS.'); }));
  document.querySelector<HTMLButtonElement>('#scan-setup')?.addEventListener('click', () => void scanSetupDevices());
  document.querySelector<HTMLButtonElement>('#setup-next')?.addEventListener('click', () => {
    const deviceUri = document.querySelector<HTMLSelectElement>('#setup-device')?.value;
    if (!deviceUri || !editing) { showToast('Hãy chọn máy in trước.', true); return; }
    editing = { ...editing, cups_device_uri: deviceUri };
    printerSetupStep = 2;
    renderDashboard();
    document.querySelector('#printer-setup')?.scrollIntoView({ behavior: 'smooth' });
  });
  document.querySelector<HTMLButtonElement>('#setup-back')?.addEventListener('click', () => { printerSetupStep = 1; renderDashboard(); });
  document.querySelector<HTMLButtonElement>('#setup-change-device')?.addEventListener('click', () => { printerSetupStep = 1; renderDashboard(); });
  document.querySelector<HTMLButtonElement>('#manual-setup')?.addEventListener('click', () => { printerSetupStep = 0; renderDashboard(); document.querySelector('#editor')?.scrollIntoView({ behavior: 'smooth' }); });
  document.querySelector<HTMLButtonElement>('#cancel-wizard')?.addEventListener('click', closePrinterSetup);
  document.querySelector<HTMLFormElement>('#printer-setup-form')?.addEventListener('submit', (event) => void saveWizardPrinter(event));
  document.querySelector<HTMLButtonElement>('#setup-test')?.addEventListener('click', () => void testSetupPrinter());
  document.querySelector<HTMLButtonElement>('#setup-skip')?.addEventListener('click', () => { setupTestPassed = false; printerSetupStep = 4; renderDashboard(); void run(loadDashboard); });
  document.querySelector<HTMLButtonElement>('#setup-finish')?.addEventListener('click', closePrinterSetup);
  document.querySelector<HTMLFormElement>('#print-profile-form')?.addEventListener('submit', (event) => void savePrintProfile(event));
  document.querySelector<HTMLButtonElement>('#import-store-profile')?.addEventListener('click', () => void importStoreProfile());
  document.querySelectorAll<HTMLButtonElement>('[data-preview]').forEach((button) => button.addEventListener('click', () => void previewPrint(button.dataset.preview as 'receipt' | 'kitchen')));
  document.querySelector<HTMLButtonElement>('#cancel-editor')?.addEventListener('click', () => { editing = null; printerSetupStep = 0; renderDashboard(); });
  document.querySelector<HTMLFormElement>('#printer-form')?.addEventListener('submit', (event) => void savePrinter(event));
  document.querySelector<HTMLButtonElement>('#setup-queue')?.addEventListener('click', () => void setupQueue());
  document.querySelectorAll<HTMLButtonElement>('[data-edit]').forEach((button) => button.addEventListener('click', () => { editing = printers.find((item) => item.id === button.dataset.edit) ?? null; printerSetupStep = 0; renderDashboard(); document.querySelector('#editor')?.scrollIntoView({ behavior: 'smooth' }); }));
  document.querySelectorAll<HTMLButtonElement>('[data-delete]').forEach((button) => button.addEventListener('click', () => void deletePrinter(button.dataset.delete ?? '')));
  document.querySelectorAll<HTMLButtonElement>('[data-test]').forEach((button) => button.addEventListener('click', () => void testPrinter(button.dataset.id ?? '', button.dataset.test ?? '')));
}

function startPrinterSetup(): void {
  editing = { id: '', name: '', connection_type: 'usb', protocol: 'escpos', port: 9100, printer_model: 'raw', role: 'receipt', area: '', station: '', paper_width_mm: 80, cut: true, beep: false, cash_drawer: false, enabled: true };
  printerSetupStep = 1;
  setupTestPassed = false;
  setupScanAttempted = false;
  scan = null;
  renderDashboard();
  document.querySelector('#printer-setup')?.scrollIntoView({ behavior: 'smooth' });
  void scanSetupDevices();
}

async function scanSetupDevices(): Promise<void> {
  setupScanAttempted = true;
  await run(async () => {
    scan = await api<CupsScan>('/api/cups/scan', { method: 'POST', body: '{}' });
    const device = scan.devices.find((item) => /^(usb|bluetooth):/i.test(item.uri));
    if (editing && !editing.cups_device_uri && device) editing = { ...editing, cups_device_uri: device.uri };
    if (device) showToast(`Đã tìm thấy ${scan.devices.filter((item) => /^(usb|bluetooth):/i.test(item.uri)).length} thiết bị.`);
  });
  renderDashboard();
  document.querySelector('#printer-setup')?.scrollIntoView({ behavior: 'smooth' });
}

function closePrinterSetup(): void {
  const refresh = Boolean(editing?.id);
  editing = null;
  printerSetupStep = 0;
  setupTestPassed = false;
  renderDashboard();
  if (refresh) void run(loadDashboard);
}

async function saveWizardPrinter(event: SubmitEvent): Promise<void> {
  event.preventDefault();
  if (!editing) return;
  const form = event.currentTarget as HTMLFormElement;
  const data = new FormData(form);
  const device = scan?.devices.find((item) => item.uri === editing?.cups_device_uri);
  if (!device) {
    showToast('Thiết bị không còn trong danh sách. Hãy quét lại máy in.', true);
    printerSetupStep = 1;
    renderDashboard();
    return;
  }

  const queue = editing.cups_queue || `airpos_${Date.now().toString(36)}`;
  const connectionType = /^usb:/i.test(device.uri) ? 'usb' : 'bluetooth';
  const name = String(data.get('name') ?? '').trim();
  if (!name) { showToast('Nhập tên máy in để tiếp tục.', true); return; }
  const role = data.get('role') === 'kitchen' ? 'kitchen' : 'receipt';
  const paperWidth = Number(data.get('paper_width_mm')) === 58 ? 58 : 80;
  const payload: Json = {
    name,
    connection_type: connectionType,
    protocol: 'escpos',
    paper_width_mm: paperWidth,
    cups_queue: queue,
    cups_device_uri: device.uri,
    printer_model: 'raw',
    host: null,
    port: 9100,
    role,
    area: '',
    station: '',
    cut: true,
    beep: false,
    cash_drawer: false,
    enabled: true,
  };
  editing = { ...editing, name, connection_type: connectionType, protocol: 'escpos', paper_width_mm: paperWidth, cups_queue: queue, cups_device_uri: device.uri, printer_model: 'raw', role };
  await run(async () => {
    const id = editing?.id;
    const saved = await api<{ printer: Printer }>(id ? `/api/printers/${encodeURIComponent(id)}` : '/api/printers', { method: id ? 'PUT' : 'POST', body: JSON.stringify(payload) });
    editing = saved.printer;
    await api(`/api/printers/${encodeURIComponent(saved.printer.id)}/setup-queue`, { method: 'POST', body: JSON.stringify({ queue, device_uri: device.uri, model: 'raw' }) });
    printerSetupStep = 3;
    showToast('Đã lưu máy in. Bây giờ hãy in thử để kiểm tra.');
  });
  renderDashboard();
  document.querySelector('#printer-setup')?.scrollIntoView({ behavior: 'smooth' });
}

async function testSetupPrinter(): Promise<void> {
  if (!editing?.id) return;
  const action = editing.role === 'kitchen' ? 'kitchen' : 'receipt';
  let testSent = false;
  await run(async () => {
    await api(`/api/printers/${encodeURIComponent(editing!.id)}/test`, { method: 'POST', body: JSON.stringify({ action }) });
    setupTestPassed = true;
    printerSetupStep = 4;
    testSent = true;
    showToast('In thử thành công.');
  });
  if (testSent) { renderDashboard(); void run(loadDashboard); }
}

async function savePrintProfile(event: SubmitEvent): Promise<void> {
  event.preventDefault();
  const form = event.currentTarget as HTMLFormElement;
  const data = new FormData(form);
  const profile: Json = {
    store_name: data.get('store_name') ?? '',
    store_name_ja: data.get('store_name_ja') ?? '',
    address: data.get('address') ?? '',
    phone: data.get('phone') ?? '',
    tax_id: data.get('tax_id') ?? '',
    currency: data.get('currency') ?? '',
    header_text_vi: data.get('header_text_vi') ?? '',
    header_text_ja: data.get('header_text_ja') ?? '',
    footer_text_vi: data.get('footer_text_vi') ?? '',
    footer_text_ja: data.get('footer_text_ja') ?? '',
    template_settings: {
      receipt_template: data.get('receipt_template'),
      kitchen_template: data.get('kitchen_template'),
      languages: String(data.get('languages') ?? 'vi,ja').split(',').filter(Boolean),
      show_order_number: data.has('show_order_number'),
      show_table: data.has('show_table'),
      show_date_time: data.has('show_date_time'),
      show_staff_name: data.has('show_staff_name'),
      show_qr_code: data.has('show_qr_code'),
      show_time_seated: data.has('show_time_seated'),
    },
  };
  await run(async () => { printProfile = await api<PrintProfileResponse>('/api/print-profile', { method: 'PUT', body: JSON.stringify(profile) }); preview = null; renderDashboard(); showToast('Đã lưu cấu hình mẫu in local.'); });
}

async function importStoreProfile(): Promise<void> {
  if (!window.confirm('Tải thông tin quán từ server? Mẫu local hiện tại sẽ được thay thế.')) return;
  await run(async () => {
    printProfile = await api<PrintProfileResponse>('/api/print-profile/import', { method: 'POST', body: '{}' });
    preview = null;
    renderDashboard();
    showToast('Đã tải thông tin quán. Có thể chỉnh rồi lưu local.');
  });
}

async function previewPrint(type: 'receipt' | 'kitchen'): Promise<void> {
  const paperWidthMm = Number(document.querySelector<HTMLSelectElement>('#preview-paper-width')?.value ?? 80);
  await run(async () => { preview = await api<PreviewResponse>('/api/print-profile/preview', { method: 'POST', body: JSON.stringify({ type, paper_width_mm: paperWidthMm }) }); renderDashboard(); showToast(`Đã tạo preview ${type}.`); });
}

async function savePrinter(event: SubmitEvent): Promise<void> {
  const form = event.currentTarget as HTMLFormElement;
  const data = new FormData(form);
  const payload: Json = { name: data.get('name'), connection_type: data.get('connection_type'), protocol: data.get('protocol'), paper_width_mm: Number(data.get('paper_width_mm')), cups_queue: data.get('cups_queue') || null, cups_device_uri: data.get('cups_device_uri') || null, printer_model: data.get('printer_model') || '', host: data.get('host') || null, port: Number(data.get('port') || 9100), role: data.get('role'), area: data.get('area') || '', station: data.get('station') || '', cut: data.has('cut'), beep: data.has('beep'), cash_drawer: data.has('cash_drawer'), enabled: true };
  await run(async () => { const id = form.dataset.id; await api(id ? `/api/printers/${encodeURIComponent(id)}` : '/api/printers', { method: id ? 'PUT' : 'POST', body: JSON.stringify(payload) }); editing = null; await loadDashboard(); showToast('Đã lưu printer profile.'); });
}

async function setupQueue(): Promise<void> {
  if (!editing?.id) return;
  const form = document.querySelector<HTMLFormElement>('#printer-form');
  if (!form) return;
  const data = new FormData(form);
  await run(async () => { await api(`/api/printers/${encodeURIComponent(editing!.id)}/setup-queue`, { method: 'POST', body: JSON.stringify({ queue: data.get('cups_queue'), device_uri: data.get('cups_device_uri'), model: data.get('printer_model') }) }); showToast('Đã tạo/cập nhật queue CUPS.'); await loadDashboard(); });
}

async function deletePrinter(id: string): Promise<void> {
  if (!id || !window.confirm('Xóa printer profile này?')) return;
  await run(async () => { await api(`/api/printers/${encodeURIComponent(id)}`, { method: 'DELETE' }); await loadDashboard(); showToast('Đã xóa profile.'); });
}

async function testPrinter(id: string, action: string): Promise<void> {
  await run(async () => { const result = await api<{ ok: boolean; detail?: string }> (`/api/printers/${encodeURIComponent(id)}/test`, { method: 'POST', body: JSON.stringify({ action }) }); showToast(result.detail || (action === 'connection' ? 'Kết nối thành công.' : 'Đã gửi lệnh test.')); await loadDashboard(); });
}

async function run(action: () => Promise<void>): Promise<void> {
  if (busy) return;
  try { setBusy(true); await action(); } catch (error) { showToast(error instanceof ApiError ? error.message : 'Không thể hoàn tất yêu cầu.', true); } finally { setBusy(false); }
}

async function boot(): Promise<void> {
  try { gatewayStatus = await api<GatewayStatus>('/api/status'); if (gatewayStatus.configured) await loadDashboard(); else renderLogin(); }
  catch (error) { renderLogin(error instanceof ApiError ? error.message : 'Không thể mở gateway.'); }
}

void boot();
