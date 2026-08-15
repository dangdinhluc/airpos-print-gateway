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

const app = document.querySelector<HTMLElement>('#app')!;
const toast = document.querySelector<HTMLElement>('#toast')!;
let gatewayStatus: GatewayStatus | null = null;
let printers: Printer[] = [];
let scan: CupsScan | null = null;
let tenants: Tenant[] = [];
let editing: Printer | null = null;
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
    <div class="brand"><span class="brand-mark">↗</span><span>AirPOS Print Gateway</span></div>
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
    <div class="brand"><span class="brand-mark">↗</span><span>AirPOS Print Gateway</span></div>
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
  const result = await api<{ printers: Printer[] }>('/api/printers');
  printers = result.printers ?? [];
  renderDashboard();
}

function renderDashboard(): void {
  const worker = gatewayStatus?.worker ?? { state: 'starting' };
  app.innerHTML = `<div class="shell"><header class="topbar"><div class="brand"><span class="brand-mark">↗</span><span>AirPOS Print Gateway</span></div><div class="top-actions"><span class="subtle">Chỉ truy cập trên máy này</span><button class="ghost" id="logout">Đăng xuất</button></div></header><div class="container">
    <div class="dashboard-head"><div><p class="eyebrow">Gateway Ubuntu</p><h1>Quản lý máy in</h1><p class="muted">Worker chạy nền kể cả khi anh đóng trình duyệt.</p></div><div class="actions"><button class="secondary" id="refresh">Làm mới</button><button class="primary" id="new-printer">Thêm máy in</button></div></div>
    <div class="status-grid"><div class="card metric"><span class="metric-label">Worker</span><div class="metric-value"><span class="dot ${dotClass(worker.state)}"></span>${esc(worker.state === 'online' ? 'Đang chạy' : worker.state === 'not_configured' ? 'Chưa cấu hình' : 'Cần kiểm tra')}</div></div><div class="card metric"><span class="metric-label">CUPS</span><div class="metric-value"><span class="dot ${scan ? 'ok' : 'warn'}"></span>${scan ? 'Đã quét' : 'Chưa quét'}</div></div><div class="card metric"><span class="metric-label">Job gần nhất</span><div class="metric-value">${esc(worker.last_job_count ?? 0)}</div></div><div class="card metric"><span class="metric-label">Phiên bản</span><div class="metric-value">Ubuntu 2.0</div></div></div>
    ${worker.last_error ? `<p class="error">${esc(worker.last_error)}</p>` : ''}
    <section class="card cups-panel"><div class="section-head"><div><h2>USB và CUPS</h2><p class="subtle">Chọn queue/device URI do CUPS trả về. Không dùng đường dẫn /dev.</p></div><button class="secondary" id="scan">Quét máy in USB</button></div>${renderScan()}</section>
    <section><div class="section-head"><div><h2>Printer profiles</h2><p class="subtle">Cấu hình được lưu local và giữ nguyên sau reboot.</p></div></div>${renderPrinters()}</section>
    ${editing ? renderEditor(editing) : ''}
  </div></div>`;
  bindDashboardEvents();
}

function renderScan(): string {
  if (!scan) return '<div class="empty">Chưa quét CUPS. Bấm “Quét máy in USB” để lấy queue, device URI và model hợp lệ.</div>';
  const devices = scan.devices.length ? scan.devices.map((item) => `<div class="scan-row"><span>${esc(item.description || item.transport)}</span><code>${esc(item.uri)}</code></div>`).join('') : '<div class="subtle">Không tìm thấy device URI.</div>';
  const queues = scan.queues.length ? scan.queues.map((item) => `<div class="scan-row"><strong>${esc(item.name)}</strong><span>${esc(item.status)}</span></div>`).join('') : '<div class="subtle">Không tìm thấy queue CUPS.</div>';
  return `<div class="scan-output"><h3>Thiết bị (${scan.devices.length})</h3>${devices}<h3>Queue (${scan.queues.length})</h3>${queues}<p class="subtle">${scan.models.length} model/driver được CUPS cung cấp${scan.default_queue ? ` · mặc định: ${esc(scan.default_queue)}` : ''}.</p></div>`;
}

function renderPrinters(): string {
  if (!printers.length) return '<div class="empty">Chưa có printer profile. Thêm máy in để worker biết nơi gửi receipt và kitchen.</div>';
  return `<div class="printer-grid">${printers.map((printer) => {
    const health = printer.health?.status ?? 'unavailable';
    const capabilities = printer.capabilities ?? { cut: false, beep: false, cash_drawer: false };
    const location = printer.connection_type === 'network' ? `${printer.host ?? ''}:${printer.port}` : (printer.cups_queue || 'Chưa có queue');
    return `<article class="card printer-card"><div class="printer-title"><div><h3>${esc(printer.name)}</h3><p class="subtle">${esc(printer.role)} · ${esc(printer.protocol)}</p></div><span class="health ${esc(health)}"><span class="dot ${dotClass(health)}"></span>${esc(friendlyStatus(health))}</span></div><div class="printer-meta"><div>Vị trí: <strong>${esc(location)}</strong></div><div>Khổ giấy: <strong>${esc(printer.paper_width_mm)}mm</strong> · ${printer.enabled ? 'Đang bật' : 'Đang tắt'}</div>${printer.health?.detail ? `<div>${esc(printer.health.detail)}</div>` : ''}${capabilities.warning ? `<div class="subtle">${esc(capabilities.warning)}</div>` : ''}</div><div class="test-actions"><button class="secondary mini" data-test="connection" data-id="${esc(printer.id)}">Kết nối</button><button class="secondary mini" data-test="receipt" data-id="${esc(printer.id)}">Receipt</button><button class="secondary mini" data-test="kitchen" data-id="${esc(printer.id)}">Kitchen</button><button class="secondary mini" data-test="cut" data-id="${esc(printer.id)}" ${capabilities.cut ? '' : 'disabled'}>Cut</button><button class="secondary mini" data-test="beep" data-id="${esc(printer.id)}" ${capabilities.beep ? '' : 'disabled'}>Beep</button><button class="secondary mini" data-test="cash_drawer" data-id="${esc(printer.id)}" ${capabilities.cash_drawer ? '' : 'disabled'}>Két tiền</button></div><div class="actions"><button class="secondary mini" data-edit="${esc(printer.id)}">Sửa</button><button class="danger mini" data-delete="${esc(printer.id)}">Xóa</button></div></article>`;
  }).join('')}</div>`;
}

function renderEditor(printer: Printer): string {
  const option = (value: string, label: string, selected: boolean) => `<option value="${value}" ${selected ? 'selected' : ''}>${label}</option>`;
  const devices = scan?.devices.map((item) => `<option value="${esc(item.uri)}">${esc(item.uri)}</option>`).join('') ?? '';
  const models = scan?.models.map((item) => `<option value="${esc(item.name)}">${esc(item.name)} — ${esc(item.description)}</option>`).join('') ?? '';
  const queues = scan?.queues.map((item) => `<option value="${esc(item.name)}">${esc(item.name)}</option>`).join('') ?? '';
  return `<section class="card editor" id="editor"><div class="section-head"><div><h2>${printer.id ? 'Sửa printer profile' : 'Thêm printer profile'}</h2><p class="subtle">Queue và driver chỉ được server chấp nhận nếu CUPS xác nhận.</p></div><button class="secondary" id="cancel-editor">Đóng</button></div><form id="printer-form" class="form-stack" data-id="${esc(printer.id)}"><div class="grid-2"><div class="field"><label for="p-name">Tên hiển thị</label><input id="p-name" name="name" value="${esc(printer.name)}" required /></div><div class="field"><label for="p-role">Vai trò</label><select id="p-role" name="role">${option('receipt', 'Receipt', printer.role === 'receipt')}${option('kitchen', 'Kitchen', printer.role === 'kitchen')}${option('qr', 'QR', printer.role === 'qr')}${option('cash_drawer', 'Két tiền', printer.role === 'cash_drawer')}</select></div></div><div class="grid-3"><div class="field"><label for="p-connection">Kết nối</label><select id="p-connection" name="connection_type">${option('usb', 'USB / CUPS', printer.connection_type === 'usb')}${option('network', 'Mạng TCP', printer.connection_type === 'network')}${option('bluetooth', 'Bluetooth / CUPS', printer.connection_type === 'bluetooth')}</select></div><div class="field"><label for="p-protocol">Protocol</label><select id="p-protocol" name="protocol">${option('escpos', 'ESC/POS raw', printer.protocol === 'escpos')}${option('star_cups', 'Star CUPS', printer.protocol === 'star_cups')}</select></div><div class="field"><label for="p-paper">Khổ giấy</label><select id="p-paper" name="paper_width_mm">${option('80', '80 mm', printer.paper_width_mm !== 58)}${option('58', '58 mm', printer.paper_width_mm === 58)}</select></div></div><div class="grid-2"><div class="field"><label for="p-queue">CUPS queue</label><input id="p-queue" name="cups_queue" list="queue-list" value="${esc(printer.cups_queue ?? '')}" placeholder="receipt_usb" /><datalist id="queue-list">${queues}</datalist></div><div class="field"><label for="p-uri">Device URI</label><input id="p-uri" name="cups_device_uri" list="device-list" value="${esc(printer.cups_device_uri ?? '')}" placeholder="usb://..." /><datalist id="device-list">${devices}</datalist></div></div><div class="grid-2"><div class="field"><label for="p-model">CUPS model/driver</label><input id="p-model" name="printer_model" list="model-list" value="${esc(printer.printer_model)}" placeholder="raw hoặc model từ lpinfo -m" /><datalist id="model-list">${models}</datalist></div><div class="field"><label for="p-host">Host mạng (nếu dùng TCP)</label><input id="p-host" name="host" value="${esc(printer.host ?? '')}" placeholder="192.168.1.20" /></div></div><div class="grid-3"><div class="field"><label for="p-area">Area</label><input id="p-area" name="area" value="${esc(printer.area)}" /></div><div class="field"><label for="p-station">Station</label><input id="p-station" name="station" value="${esc(printer.station)}" /></div><div class="field"><label for="p-port">Port</label><input id="p-port" name="port" type="number" min="1" max="65535" value="${esc(printer.port)}" /></div></div><div class="grid-3"><label class="check-row"><input type="checkbox" name="cut" ${printer.cut ? 'checked' : ''} /> Cut</label><label class="check-row"><input type="checkbox" name="beep" ${printer.beep ? 'checked' : ''} /> Beep</label><label class="check-row"><input type="checkbox" name="cash_drawer" ${printer.cash_drawer ? 'checked' : ''} /> Cash drawer</label></div><div class="actions right"><button class="primary" type="submit">Lưu profile</button><button class="secondary" type="button" id="setup-queue" ${printer.id ? '' : 'disabled'}>Tạo/cập nhật queue</button></div></form></section>`;
}

function bindDashboardEvents(): void {
  document.querySelector<HTMLButtonElement>('#logout')?.addEventListener('click', async () => { await api('/api/auth/logout', { method: 'POST', body: '{}' }).catch(() => undefined); gatewayStatus = null; renderLogin(); });
  document.querySelector<HTMLButtonElement>('#refresh')?.addEventListener('click', () => void run(loadDashboard));
  document.querySelector<HTMLButtonElement>('#new-printer')?.addEventListener('click', () => { editing = { id: '', name: '', connection_type: 'usb', protocol: 'escpos', port: 9100, printer_model: 'raw', role: 'receipt', area: '', station: '', paper_width_mm: 80, cut: true, beep: false, cash_drawer: false, enabled: true }; renderDashboard(); document.querySelector('#editor')?.scrollIntoView({ behavior: 'smooth' }); });
  document.querySelector<HTMLButtonElement>('#scan')?.addEventListener('click', () => void run(async () => { const result = await api<CupsScan & { ok: boolean }>('/api/cups/scan', { method: 'POST', body: '{}' }); scan = result; renderDashboard(); showToast('Đã quét CUPS.'); }));
  document.querySelector<HTMLButtonElement>('#cancel-editor')?.addEventListener('click', () => { editing = null; renderDashboard(); });
  document.querySelector<HTMLFormElement>('#printer-form')?.addEventListener('submit', (event) => void savePrinter(event));
  document.querySelector<HTMLButtonElement>('#setup-queue')?.addEventListener('click', () => void setupQueue());
  document.querySelectorAll<HTMLButtonElement>('[data-edit]').forEach((button) => button.addEventListener('click', () => { editing = printers.find((item) => item.id === button.dataset.edit) ?? null; renderDashboard(); document.querySelector('#editor')?.scrollIntoView({ behavior: 'smooth' }); }));
  document.querySelectorAll<HTMLButtonElement>('[data-delete]').forEach((button) => button.addEventListener('click', () => void deletePrinter(button.dataset.delete ?? '')));
  document.querySelectorAll<HTMLButtonElement>('[data-test]').forEach((button) => button.addEventListener('click', () => void testPrinter(button.dataset.id ?? '', button.dataset.test ?? '')));
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
