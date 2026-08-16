import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'config_store.dart';
import 'cups.dart';
import 'escpos.dart';
import 'gateway_api.dart';
import 'models.dart';
import 'print_profile.dart';
import 'runtime_settings.dart';
import 'runtime_status.dart';
import 'worker.dart';

typedef GatewaySnapshotReader = GatewayRuntimeSnapshot Function();
typedef GatewayClientFactory =
    SupabaseGatewayClient Function(
      GatewayRuntimeSettings settings, {
      String tenantId,
      String gatewayId,
      String gatewayToken,
    });

SupabaseGatewayClient _defaultGatewayClientFactory(
  GatewayRuntimeSettings settings, {
  String tenantId = '',
  String gatewayId = '',
  String gatewayToken = '',
}) {
  return SupabaseGatewayClient.fromSettings(
    settings,
    tenantId: tenantId,
    gatewayId: gatewayId,
    gatewayToken: gatewayToken,
  );
}

class GatewayWebServer {
  GatewayWebServer({
    required this.settings,
    required this.store,
    required this.webRoot,
    required this.snapshot,
    required this.onConfigurationChanged,
    CupsDiscoveryService? discovery,
    GatewayPrinterService? printerService,
    GatewayClientFactory? clientFactory,
  }) : _discovery = discovery ?? const CupsDiscoveryService(),
       _printerService = printerService ?? GatewayPrinterService(),
       _clientFactory = clientFactory ?? _defaultGatewayClientFactory;

  final GatewayRuntimeSettings settings;
  final GatewayConfigStore store;
  final Directory webRoot;
  final GatewaySnapshotReader snapshot;
  final void Function() onConfigurationChanged;
  final CupsDiscoveryService _discovery;
  final GatewayPrinterService _printerService;
  final GatewayClientFactory _clientFactory;
  final Map<String, _SetupSession> _sessions = <String, _SetupSession>{};
  final Random _random = Random.secure();

  HttpServer? _server;

  int get boundPort => _server?.port ?? settings.webPort;

  Future<void> start() async {
    _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      settings.webPort,
    );
    _server!.listen(
      _handleRequest,
      onError: (Object error) {
        stderr.writeln('[airpos-print-gateway] web server error: $error');
      },
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path == '/healthz') {
        await _json(request, HttpStatus.ok, <String, Object?>{
          'ok': true,
          'state': snapshot().state,
        });
        return;
      }
      if (request.uri.path.startsWith('/api/')) {
        await _handleApi(request);
        return;
      }
      await _serveStatic(request);
    } on _WebException catch (error) {
      await _json(request, error.statusCode, <String, Object?>{
        'ok': false,
        'code': error.code,
        'message': error.message,
      });
    } on CupsException catch (error) {
      await _json(request, HttpStatus.badRequest, <String, Object?>{
        'ok': false,
        'code': error.status.name,
        'message': error.message,
      });
    } on GatewayApiException catch (error) {
      await _json(request, _gatewayStatusCode(error), <String, Object?>{
        'ok': false,
        'code': 'CONTROL_PLANE_ERROR',
        'message': _gatewayMessage(error),
      });
    } catch (error, stackTrace) {
      stderr.writeln('[airpos-print-gateway] web request failed: $error');
      stderr.writeln(stackTrace);
      await _json(request, HttpStatus.internalServerError, <String, Object?>{
        'ok': false,
        'code': 'INTERNAL_ERROR',
        'message': 'Không thể hoàn tất yêu cầu.',
      });
    }
  }

  Future<void> _handleApi(HttpRequest request) async {
    final path = request.uri.path;
    final parts = request.uri.pathSegments;

    if (request.method == 'GET' && path == '/api/status') {
      await _json(request, HttpStatus.ok, await _status());
      return;
    }
    if (request.method == 'POST' && path == '/api/auth/login') {
      await _login(request);
      return;
    }
    if (request.method == 'POST' && path == '/api/auth/provision') {
      await _provision(request);
      return;
    }
    if (request.method == 'POST' && path == '/api/auth/logout') {
      _sessions.remove(_sessionId(request));
      await _json(
        request,
        HttpStatus.ok,
        <String, Object?>{'ok': true},
        setCookies: <String>[_clearSessionCookie()],
      );
      return;
    }
    if (request.method == 'GET' && path == '/api/print-profile') {
      await _getPrintProfile(request);
      return;
    }
    if (request.method == 'PUT' && path == '/api/print-profile') {
      await _putPrintProfile(request);
      return;
    }
    if (request.method == 'POST' && path == '/api/print-profile/preview') {
      await _previewPrintProfile(request);
      return;
    }
    if (request.method == 'POST' && path == '/api/cups/scan') {
      await _scanCups(request);
      return;
    }
    if (request.method == 'GET' && path == '/api/printers') {
      await _listPrinters(request);
      return;
    }
    if (request.method == 'POST' && path == '/api/printers') {
      await _savePrinter(request);
      return;
    }
    if (parts.length == 3 && parts[0] == 'api' && parts[1] == 'printers') {
      final printerId = parts[2];
      if (request.method == 'PUT') {
        await _savePrinter(request, printerId: printerId);
        return;
      }
      if (request.method == 'DELETE') {
        await _deletePrinter(request, printerId);
        return;
      }
    }
    if (parts.length == 4 && parts[0] == 'api' && parts[1] == 'printers') {
      final printerId = parts[2];
      if (request.method == 'POST' && parts[3] == 'setup-queue') {
        await _setupQueue(request, printerId);
        return;
      }
      if (request.method == 'POST' && parts[3] == 'test') {
        await _testPrinter(request, printerId);
        return;
      }
    }
    throw const _WebException(
      HttpStatus.notFound,
      'NOT_FOUND',
      'Không tìm thấy yêu cầu.',
    );
  }

  Future<void> _login(HttpRequest request) async {
    final body = await _readBody(request);
    final email = _text(body['email']);
    final password = body['password']?.toString() ?? '';
    if (email.isEmpty || password.isEmpty) {
      throw const _WebException(
        HttpStatus.badRequest,
        'LOGIN_REQUIRED',
        'Hãy nhập email và mật khẩu.',
      );
    }

    final client = _client();
    late final GatewayLoginResult result;
    try {
      result = await client.loginAndFetchTenants(email, password);
    } finally {
      client.close();
    }
    if (result.tenants.isEmpty) {
      throw const _WebException(
        HttpStatus.forbidden,
        'NO_TENANT',
        'Tài khoản chưa được gắn với quán nào.',
      );
    }

    final sessionId = _newSessionId();
    _sessions[sessionId] = _SetupSession(
      accessToken: result.accessToken,
      tenants: result.tenants,
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
    if (result.tenants.length == 1) {
      final tenant = result.tenants.first;
      await _finishProvision(sessionId, tenant);
      await _json(request, HttpStatus.ok, <String, Object?>{
        'ok': true,
        'state': 'provisioned',
        'tenant': _tenantJson(tenant),
      });
      return;
    }
    await _json(
      request,
      HttpStatus.ok,
      <String, Object?>{
        'ok': true,
        'state': 'choose_tenant',
        'tenants': result.tenants.map(_tenantJson).toList(growable: false),
      },
      setCookies: <String>[_sessionCookie(sessionId)],
    );
  }

  Future<void> _provision(HttpRequest request) async {
    final sessionId = _sessionId(request);
    final session = _activeSession(sessionId);
    final body = await _readBody(request);
    final tenantId = _text(body['tenant_id']);
    final tenant = session.tenants.cast<TenantOption?>().firstWhere(
      (item) => item?.tenantId == tenantId,
      orElse: () => null,
    );
    if (tenant == null) {
      throw const _WebException(
        HttpStatus.forbidden,
        'TENANT_NOT_ALLOWED',
        'Quán được chọn không thuộc tài khoản này.',
      );
    }
    await _finishProvision(sessionId, tenant);
    await _json(
      request,
      HttpStatus.ok,
      <String, Object?>{
        'ok': true,
        'state': 'provisioned',
        'tenant': _tenantJson(tenant),
      },
      setCookies: <String>[_clearSessionCookie()],
    );
  }

  Future<void> _finishProvision(String sessionId, TenantOption tenant) async {
    final session = _activeSession(sessionId);
    final client = _client();
    late final GatewayProvisionResult provision;
    try {
      provision = await client.registerGateway(
        accessToken: session.accessToken,
        selectedTenantId: tenant.tenantId,
        gatewayName: 'AirPOS Ubuntu Gateway',
        fingerprint: await _fingerprint(),
        appVersion: settings.appVersion,
      );
    } finally {
      client.close();
    }
    await store.saveConfig(
      GatewayConfig(
        tenantId: tenant.tenantId,
        gatewayId: provision.gatewayId,
        gatewayToken: provision.gatewayToken,
        pollIntervalSeconds: provision.pollIntervalSeconds,
        appVersion: settings.appVersion,
      ),
    );
    // ponytail: templates are gateway-local; never import or overwrite them
    // from the server. A later optional import must be an explicit new feature.
    _sessions.remove(sessionId);
    onConfigurationChanged();
  }

  Future<void> _getPrintProfile(HttpRequest request) async {
    final profile = await store.loadPrintProfile();
    await _json(request, HttpStatus.ok, <String, Object?>{
      'ok': true,
      'profile': _printProfileJson(profile),
      'sync': _printProfileSyncJson(profile),
      'font_warning': _printerService.fontWarning,
    });
  }

  Future<void> _putPrintProfile(HttpRequest request) async {
    final current = await store.loadPrintProfile();
    final next = _validatedPrintProfile(await _readBody(request), current);
    await store.savePrintProfile(next);
    onConfigurationChanged();
    final saved = await store.loadPrintProfile();
    await _json(request, HttpStatus.ok, <String, Object?>{
      'ok': true,
      'profile': _printProfileJson(saved),
      'sync': _printProfileSyncJson(saved),
      'font_warning': _printerService.fontWarning,
    });
  }

  Future<void> _previewPrintProfile(HttpRequest request) async {
    final body = await _readBody(request);
    final type = body['type'];
    if (type is! String || (type != 'receipt' && type != 'kitchen')) {
      throw const _WebException(
        HttpStatus.badRequest,
        'PREVIEW_TYPE_INVALID',
        'Loại bản xem thử không hợp lệ.',
      );
    }
    final profile = await store.loadPrintProfile();
    final paperWidthMm = body['paper_width_mm'] == 58 ? 58 : 80;
    final template = type == 'kitchen'
        ? profile.templateSettings.kitchenTemplate
        : profile.templateSettings.receiptTemplate;
    await _json(request, HttpStatus.ok, <String, Object?>{
      'ok': true,
      'type': type,
      'template': template,
      'paper_width_mm': paperWidthMm,
      'text': _printerService.previewText(
        type: type,
        printProfile: profile,
        paperWidthMm: paperWidthMm,
      ),
    });
  }

  Future<void> _scanCups(HttpRequest request) async {
    final snapshot = await _discovery.discover();
    await _json(request, HttpStatus.ok, <String, Object?>{
      'ok': true,
      'devices': snapshot.devices
          .map(
            (device) => <String, Object?>{
              'transport': device.transport,
              'uri': device.uri,
              'description': device.description,
            },
          )
          .toList(growable: false),
      'queues': snapshot.queues
          .map(
            (queue) => <String, Object?>{
              'name': queue.name,
              'status': queue.status,
              'disabled': queue.isDisabled,
            },
          )
          .toList(growable: false),
      'models': snapshot.models
          .map(
            (model) => <String, Object?>{
              'name': model.name,
              'description': model.description,
            },
          )
          .toList(growable: false),
      'default_queue': snapshot.defaultQueue,
    });
  }

  Future<void> _listPrinters(HttpRequest request) async {
    final profiles = await store.loadPrinters();
    final result = <Map<String, Object?>>[];
    for (final profile in profiles) {
      final json = Map<String, Object?>.from(profile.toJson());
      final health = await _printerService.testConnection(profile);
      final capabilities = await _printerService.probeCapabilities(profile);
      json['health'] = <String, Object?>{
        'status': health.status.value,
        'detail': health.detail,
      };
      json['capabilities'] = capabilities.toJson();
      result.add(json);
    }
    await _json(request, HttpStatus.ok, <String, Object?>{
      'ok': true,
      'printers': result,
    });
  }

  Future<void> _savePrinter(HttpRequest request, {String? printerId}) async {
    final body = await _readBody(request);
    final name = _text(body['name']);
    if (name.isEmpty) {
      throw const _WebException(
        HttpStatus.badRequest,
        'PRINTER_NAME_REQUIRED',
        'Tên máy in không được để trống.',
      );
    }
    final profile = PrinterProfile.fromJson(<String, dynamic>{
      ...body,
      'name': name,
      if (printerId != null) 'id': printerId,
    });
    final queue = profile.cupsQueue?.trim() ?? '';
    if (queue.isNotEmpty && !isSafeQueueName(queue)) {
      throw const _WebException(
        HttpStatus.badRequest,
        'QUEUE_INVALID',
        'Tên CUPS queue không hợp lệ.',
      );
    }
    final deviceUri = profile.cupsDeviceUri?.trim() ?? '';
    if (deviceUri.isNotEmpty && !isSafeDeviceUri(deviceUri)) {
      throw const _WebException(
        HttpStatus.badRequest,
        'DEVICE_URI_INVALID',
        'Device URI không hợp lệ.',
      );
    }
    if (profile.printerModel.contains(RegExp(r'[\r\n]'))) {
      throw const _WebException(
        HttpStatus.badRequest,
        'MODEL_INVALID',
        'Printer model không hợp lệ.',
      );
    }
    // Capabilities come from the local driver, never from browser JSON.
    final sanitized = profile.copyWith(
      capabilities: defaultCapabilities(
        profile.connectionType,
        profile.protocol,
      ),
    );
    final profiles = await store.loadPrinters();
    final next = <PrinterProfile>[
      ...profiles.where((item) => item.id != sanitized.id),
      sanitized,
    ];
    await store.savePrinters(next);
    onConfigurationChanged();
    await _json(request, HttpStatus.ok, <String, Object?>{
      'ok': true,
      'printer': sanitized.toJson(),
    });
  }

  Future<void> _deletePrinter(HttpRequest request, String printerId) async {
    final profiles = await store.loadPrinters();
    if (!profiles.any((profile) => profile.id == printerId)) {
      throw const _WebException(
        HttpStatus.notFound,
        'PRINTER_NOT_FOUND',
        'Không tìm thấy profile máy in.',
      );
    }
    await store.savePrinters(
      profiles.where((profile) => profile.id != printerId),
    );
    onConfigurationChanged();
    await _json(request, HttpStatus.ok, <String, Object?>{'ok': true});
  }

  Future<void> _setupQueue(HttpRequest request, String printerId) async {
    final profile = await _findPrinter(printerId);
    final body = await _readBody(request);
    final queue = _text(body['queue']).isEmpty
        ? profile.cupsQueue?.trim() ?? ''
        : _text(body['queue']);
    final deviceUri = _text(body['device_uri']).isEmpty
        ? profile.cupsDeviceUri?.trim() ?? ''
        : _text(body['device_uri']);
    final model = _text(body['model']).isEmpty
        ? (profile.printerModel.trim().isEmpty &&
                  profile.protocol == PrinterProtocol.escpos
              ? 'raw'
              : profile.printerModel.trim())
        : _text(body['model']);
    await CupsSetupService(
      discovery: _discovery,
    ).createQueue(queue: queue, deviceUri: deviceUri, model: model);
    await _json(request, HttpStatus.ok, <String, Object?>{
      'ok': true,
      'queue': queue,
    });
  }

  Future<void> _testPrinter(HttpRequest request, String printerId) async {
    final profile = await _findPrinter(printerId);
    final body = await _readBody(request);
    final actionName = _text(body['action']).toLowerCase();
    if (actionName == 'connection') {
      final health = await _printerService.testConnection(profile);
      await _json(request, HttpStatus.ok, <String, Object?>{
        'ok': health.status == PrinterHealthStatus.connected,
        'status': health.status.value,
        'detail': health.detail,
        'message': health.status == PrinterHealthStatus.connected
            ? null
            : health.detail ?? 'Không thể kết nối máy in.',
      });
      return;
    }
    final action = TestPrintAction.values.firstWhere(
      (item) => item.name == actionName,
      orElse: () => throw const _WebException(
        HttpStatus.badRequest,
        'TEST_ACTION_INVALID',
        'Thao tác test không hợp lệ.',
      ),
    );
    final capabilities = await _printerService.probeCapabilities(profile);
    final supported = switch (action) {
      TestPrintAction.cut => capabilities.cut,
      TestPrintAction.beep => capabilities.beep,
      TestPrintAction.cashDrawer => capabilities.cashDrawer,
      _ => true,
    };
    if (!supported) {
      throw _WebException(
        HttpStatus.badRequest,
        'CAPABILITY_UNSUPPORTED',
        capabilities.warning ?? 'Driver không hỗ trợ tính năng này.',
      );
    }
    await _printerService.test(
      profile,
      action,
      printProfile: await store.loadPrintProfile(),
    );
    await _json(request, HttpStatus.ok, <String, Object?>{'ok': true});
  }

  Future<Map<String, Object?>> _status() async {
    final config = await store.loadConfig();
    return <String, Object?>{
      'ok': true,
      'configured': config?.isProvisioned == true,
      'worker': snapshot().toJson(),
    };
  }

  Future<PrinterProfile> _findPrinter(String printerId) async {
    final profiles = await store.loadPrinters();
    for (final profile in profiles) {
      if (profile.id == printerId) return profile;
    }
    throw const _WebException(
      HttpStatus.notFound,
      'PRINTER_NOT_FOUND',
      'Không tìm thấy profile máy in.',
    );
  }

  SupabaseGatewayClient _client({
    String tenantId = '',
    String gatewayId = '',
    String gatewayToken = '',
  }) {
    try {
      return _clientFactory(
        settings,
        tenantId: tenantId,
        gatewayId: gatewayId,
        gatewayToken: gatewayToken,
      );
    } on StateError {
      throw const _WebException(
        HttpStatus.internalServerError,
        'RUNTIME_NOT_CONFIGURED',
        'Gateway chưa được cấu hình hệ thống.',
      );
    }
  }

  _SetupSession _activeSession(String id) {
    final session = _sessions[id];
    if (session == null || session.expiresAt.isBefore(DateTime.now())) {
      _sessions.remove(id);
      throw const _WebException(
        HttpStatus.unauthorized,
        'SESSION_EXPIRED',
        'Phiên đăng nhập đã hết hạn, hãy đăng nhập lại.',
      );
    }
    return session;
  }

  String _newSessionId() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _sessionId(HttpRequest request) {
    final header = request.headers.value('cookie') ?? '';
    for (final item in header.split(';')) {
      final parts = item.trim().split('=');
      if (parts.length >= 2 && parts.first == 'airpos_setup') {
        return parts.sublist(1).join('=');
      }
    }
    return '';
  }

  String _sessionCookie(String id) =>
      'airpos_setup=$id; Path=/; HttpOnly; SameSite=Strict; Max-Age=600';

  String _clearSessionCookie() =>
      'airpos_setup=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0';

  Future<String> _fingerprint() async {
    final machineId = File('/etc/machine-id');
    if (await machineId.exists()) {
      final value = (await machineId.readAsString()).trim();
      if (value.isNotEmpty) return value;
    }
    return 'ubuntu-${Platform.localHostname}';
  }

  Future<Map<String, dynamic>> _readBody(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (raw.length > 1024 * 1024) {
      throw const _WebException(
        HttpStatus.requestEntityTooLarge,
        'REQUEST_TOO_LARGE',
        'Dữ liệu gửi lên quá lớn.',
      );
    }
    if (raw.trim().isEmpty) return <String, dynamic>{};
    late final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const _WebException(
        HttpStatus.badRequest,
        'JSON_INVALID',
        'Dữ liệu không hợp lệ.',
      );
    }
    if (decoded is! Map) {
      throw const _WebException(
        HttpStatus.badRequest,
        'JSON_INVALID',
        'Dữ liệu không hợp lệ.',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _serveStatic(HttpRequest request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      throw const _WebException(
        HttpStatus.methodNotAllowed,
        'METHOD_NOT_ALLOWED',
        'Phương thức không được hỗ trợ.',
      );
    }
    var relative = request.uri.path == '/'
        ? 'index.html'
        : Uri.decodeComponent(request.uri.path.substring(1));
    if (relative.contains('..') || relative.contains('\\')) {
      throw const _WebException(
        HttpStatus.forbidden,
        'PATH_INVALID',
        'Đường dẫn không hợp lệ.',
      );
    }
    var file = File('${webRoot.path}/$relative');
    if (!await file.exists() || relative.isEmpty) {
      file = File('${webRoot.path}/index.html');
    }
    if (!await file.exists()) {
      throw const _WebException(
        HttpStatus.notFound,
        'WEB_ASSETS_MISSING',
        'Không tìm thấy giao diện web.',
      );
    }
    request.response.headers.contentType = _contentType(file.path);
    request.response.headers.set('cache-control', 'no-cache');
    if (request.method == 'GET') {
      request.response.add(await file.readAsBytes());
    }
    await request.response.close();
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Object body, {
    List<String> setCookies = const <String>[],
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('cache-control', 'no-store');
    for (final cookie in setCookies) {
      request.response.headers.add('set-cookie', cookie);
    }
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

class _SetupSession {
  const _SetupSession({
    required this.accessToken,
    required this.tenants,
    required this.expiresAt,
  });

  final String accessToken;
  final List<TenantOption> tenants;
  final DateTime expiresAt;
}

class _WebException implements Exception {
  const _WebException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;
}

Map<String, Object?> _tenantJson(TenantOption tenant) => <String, Object?>{
  'tenant_id': tenant.tenantId,
  'slug': tenant.slug,
  'name': tenant.name,
  'role': tenant.role,
};

String _text(Object? value) => value?.toString().trim() ?? '';

Map<String, Object?> _printProfileJson(StorePrintProfile profile) =>
    <String, Object?>{
      'store_name': profile.storeName,
      'store_name_ja': profile.storeNameJa,
      'address': profile.address,
      'phone': profile.phone,
      'tax_id': profile.taxId,
      'currency': profile.currency,
      'header_text_vi': profile.headerTextVi,
      'header_text_ja': profile.headerTextJa,
      'footer_text_vi': profile.footerTextVi,
      'footer_text_ja': profile.footerTextJa,
      'template_settings': profile.templateSettings.toJson(),
    };

Map<String, Object?> _printProfileSyncJson(
  StorePrintProfile profile,
) => <String, Object?>{
  'last_synced_at': profile.lastSyncedAt,
  'local_edited_at': profile.localEditedAt,
  'warning': profile.lastSyncedAt == null
      ? 'Chưa đồng bộ cấu hình in từ hệ thống. Đang dùng cấu hình mặc định trên máy.'
      : null,
};

StorePrintProfile _validatedPrintProfile(
  Map<String, dynamic> body,
  StorePrintProfile current,
) {
  final rawProfile = body['profile'];
  if (rawProfile != null && body.keys.any((key) => key != 'profile')) {
    throw const _WebException(
      HttpStatus.badRequest,
      'PROFILE_FIELD_INVALID',
      'Trường cấu hình in không được hỗ trợ.',
    );
  }
  final input = rawProfile == null
      ? body
      : (rawProfile is Map
            ? Map<String, dynamic>.from(rawProfile)
            : throw const _WebException(
                HttpStatus.badRequest,
                'PROFILE_INVALID',
                'Dữ liệu cấu hình in không hợp lệ.',
              ));
  const stringLimits = <String, int>{
    'store_name': 120,
    'store_name_ja': 120,
    'address': 240,
    'phone': 40,
    'tax_id': 80,
    'currency': 8,
    'header_text_vi': 500,
    'header_text_ja': 500,
    'footer_text_vi': 500,
    'footer_text_ja': 500,
  };
  const allowedTopLevel = <String>{
    'store_name',
    'store_name_ja',
    'address',
    'phone',
    'tax_id',
    'currency',
    'header_text_vi',
    'header_text_ja',
    'footer_text_vi',
    'footer_text_ja',
    'template_settings',
  };
  for (final key in input.keys) {
    if (!allowedTopLevel.contains(key)) {
      throw const _WebException(
        HttpStatus.badRequest,
        'PROFILE_FIELD_INVALID',
        'Trường cấu hình in không được hỗ trợ.',
      );
    }
  }
  final strings = <String, String>{};
  for (final entry in stringLimits.entries) {
    if (!input.containsKey(entry.key)) continue;
    final value = input[entry.key];
    if (value is! String) {
      throw const _WebException(
        HttpStatus.badRequest,
        'PROFILE_FIELD_INVALID',
        'Trường cấu hình in phải là chuỗi.',
      );
    }
    if (value.length > entry.value) {
      throw const _WebException(
        HttpStatus.badRequest,
        'PROFILE_FIELD_TOO_LONG',
        'Trường cấu hình in quá dài.',
      );
    }
    strings[entry.key] = value;
  }

  var templateSettings = current.templateSettings;
  if (input.containsKey('template_settings')) {
    final rawTemplates = input['template_settings'];
    if (rawTemplates is! Map) {
      throw const _WebException(
        HttpStatus.badRequest,
        'TEMPLATE_SETTINGS_INVALID',
        'Cấu hình mẫu in không hợp lệ.',
      );
    }
    templateSettings = _validatedTemplateSettings(
      Map<String, dynamic>.from(rawTemplates),
      current.templateSettings,
    );
  }

  return current.copyWith(
    storeName: strings['store_name'],
    storeNameJa: strings['store_name_ja'],
    address: strings['address'],
    phone: strings['phone'],
    taxId: strings['tax_id'],
    currency: strings['currency'],
    headerTextVi: strings['header_text_vi'],
    headerTextJa: strings['header_text_ja'],
    footerTextVi: strings['footer_text_vi'],
    footerTextJa: strings['footer_text_ja'],
    templateSettings: templateSettings,
  );
}

TemplateSettings _validatedTemplateSettings(
  Map<String, dynamic> input,
  TemplateSettings current,
) {
  const allowed = <String>{
    'receipt_template',
    'kitchen_template',
    'languages',
    'show_order_number',
    'show_table',
    'show_date_time',
    'show_staff_name',
    'show_qr_code',
    'show_time_seated',
  };
  for (final key in input.keys) {
    if (!allowed.contains(key)) {
      throw const _WebException(
        HttpStatus.badRequest,
        'TEMPLATE_FIELD_INVALID',
        'Trường mẫu in không được hỗ trợ.',
      );
    }
  }
  final receiptTemplate = _optionalEnum(
    input,
    'receipt_template',
    const <String>{'modern', 'classic', 'compact', 'detailed'},
    'Mẫu hóa đơn không được hỗ trợ.',
  );
  final kitchenTemplate = _optionalEnum(
    input,
    'kitchen_template',
    const <String>{'standard', 'compact', 'checklist'},
    'Mẫu bếp không được hỗ trợ.',
  );
  final languages = input.containsKey('languages')
      ? _validatedLanguages(input['languages'])
      : null;
  bool? boolField(String key) {
    if (!input.containsKey(key)) return null;
    final value = input[key];
    if (value is bool) return value;
    throw const _WebException(
      HttpStatus.badRequest,
      'TEMPLATE_FIELD_INVALID',
      'Tuỳ chọn mẫu in phải là true hoặc false.',
    );
  }

  return current.copyWith(
    receiptTemplate: receiptTemplate,
    kitchenTemplate: kitchenTemplate,
    languages: languages,
    showOrderNumber: boolField('show_order_number'),
    showTable: boolField('show_table'),
    showDateTime: boolField('show_date_time'),
    showStaffName: boolField('show_staff_name'),
    showQrCode: boolField('show_qr_code'),
    showTimeSeated: boolField('show_time_seated'),
  );
}

String? _optionalEnum(
  Map<String, dynamic> input,
  String key,
  Set<String> allowed,
  String message,
) {
  if (!input.containsKey(key)) return null;
  final value = input[key];
  if (value is! String || value.length > 40) {
    throw _WebException(
      HttpStatus.badRequest,
      'TEMPLATE_FIELD_INVALID',
      message,
    );
  }
  final normalized = value.trim().toLowerCase();
  if (!allowed.contains(normalized)) {
    throw _WebException(
      HttpStatus.badRequest,
      'TEMPLATE_FIELD_INVALID',
      message,
    );
  }
  return normalized;
}

List<String>? _validatedLanguages(Object? value) {
  if (value is! List || value.isEmpty || value.length > 8) {
    throw const _WebException(
      HttpStatus.badRequest,
      'LANGUAGES_INVALID',
      'Danh sách ngôn ngữ không hợp lệ.',
    );
  }
  const allowed = <String>{'vi', 'ja', 'en', 'zh', 'ko', 'id', 'my'};
  final languages = <String>[];
  for (final item in value) {
    if (item is! String || item.length > 8) {
      throw const _WebException(
        HttpStatus.badRequest,
        'LANGUAGES_INVALID',
        'Danh sách ngôn ngữ không hợp lệ.',
      );
    }
    final language = item.trim().toLowerCase();
    if (!allowed.contains(language)) {
      throw const _WebException(
        HttpStatus.badRequest,
        'LANGUAGE_UNSUPPORTED',
        'Ngôn ngữ in không được hỗ trợ.',
      );
    }
    if (!languages.contains(language)) languages.add(language);
  }
  return languages;
}

int _gatewayStatusCode(GatewayApiException error) {
  if (error.statusCode == 401 || error.statusCode == 403) {
    return HttpStatus.unauthorized;
  }
  return HttpStatus.badGateway;
}

String _gatewayMessage(GatewayApiException error) {
  if (error.statusCode == 401 || error.statusCode == 403) {
    return 'Tài khoản hoặc mật khẩu không đúng.';
  }
  return 'Không kết nối được hệ thống. Hãy thử lại sau.';
}

ContentType _contentType(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.html')) return ContentType.html;
  if (lower.endsWith('.css'))
    return ContentType('text', 'css', charset: 'utf-8');
  if (lower.endsWith('.js')) {
    return ContentType('text', 'javascript', charset: 'utf-8');
  }
  if (lower.endsWith('.svg')) return ContentType('image', 'svg+xml');
  if (lower.endsWith('.json')) return ContentType.json;
  return ContentType('application', 'octet-stream');
}
