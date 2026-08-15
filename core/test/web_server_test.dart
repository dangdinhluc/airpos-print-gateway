import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:airpos_print_gateway_core/airpos_print_gateway_core.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  test(
    'serves loopback health/status without returning gateway secrets',
    () async {
      final directory = await Directory.systemTemp.createTemp('airpos-web-');
      final webRoot = await Directory('${directory.path}/web').create();
      await File('${webRoot.path}/index.html').writeAsString('gateway-ui');
      addTearDown(() => directory.delete(recursive: true));
      final store = GatewayConfigStore(configDirectory: directory.path);
      await store.saveConfig(
        const GatewayConfig(
          tenantId: 'tenant-1',
          gatewayId: 'gateway-1',
          gatewayToken: 'do-not-return-this',
        ),
      );
      final server = GatewayWebServer(
        settings: const GatewayRuntimeSettings(
          supabaseUrl: 'https://control.example.test',
          supabaseAnonKey: 'compiled-anon-key',
          webPort: 0,
        ),
        store: store,
        webRoot: webRoot,
        snapshot: () => const GatewayRuntimeSnapshot(state: 'online'),
        onConfigurationChanged: () {},
      );
      await server.start();
      addTearDown(server.stop);

      final health = await _get(server.boundPort, '/healthz');
      final status = await _get(server.boundPort, '/api/status');
      final index = await _get(server.boundPort, '/');

      expect(health.statusCode, HttpStatus.ok);
      expect(health.body, contains('"ok":true'));
      expect(status.statusCode, HttpStatus.ok);
      expect(status.body, contains('"configured":true'));
      expect(status.body, isNot(contains('do-not-return-this')));
      expect(status.body, isNot(contains('compiled-anon-key')));
      expect(index.body, 'gateway-ui');
    },
  );

  test(
    'login auto-provisions one tenant and keeps credentials out of response',
    () async {
      final directory = await Directory.systemTemp.createTemp('airpos-login-');
      final webRoot = await Directory('${directory.path}/web').create();
      await File('${webRoot.path}/index.html').writeAsString('gateway-ui');
      addTearDown(() => directory.delete(recursive: true));
      final store = GatewayConfigStore(configDirectory: directory.path);
      final server = GatewayWebServer(
        settings: const GatewayRuntimeSettings(
          supabaseUrl: 'https://control.example.test',
          supabaseAnonKey: 'compiled-anon-key',
          webPort: 0,
        ),
        store: store,
        webRoot: webRoot,
        snapshot: () => const GatewayRuntimeSnapshot(state: 'not_configured'),
        onConfigurationChanged: () {},
        clientFactory:
            (_, {tenantId = '', gatewayId = '', gatewayToken = ''}) =>
                SupabaseGatewayClient(
                  baseUrl: 'https://control.example.test',
                  anonKey: 'compiled-anon-key',
                  tenantId: tenantId,
                  gatewayId: gatewayId,
                  gatewayToken: gatewayToken,
                  client: _FakeControlPlaneClient(singleTenant: true),
                ),
      );
      await server.start();
      addTearDown(server.stop);

      final response = await _post(
        server.boundPort,
        '/api/auth/login',
        <String, Object?>{
          'email': 'owner@example.test',
          'password': 'password',
        },
      );
      final config = await store.loadConfig();

      expect(response.statusCode, HttpStatus.ok);
      expect(response.body, contains('"state":"provisioned"'));
      expect(response.body, isNot(contains('gateway-token')));
      expect(config?.tenantId, 'tenant-1');
      expect(config?.gatewayId, 'gateway-1');
      expect((await store.loadPrintProfile()).storeName, 'Seed Store');
    },
  );

  test('print profile GET and PUT return only safe local data', () async {
    final directory = await Directory.systemTemp.createTemp('airpos-profile-');
    final webRoot = await Directory('${directory.path}/web').create();
    await File('${webRoot.path}/index.html').writeAsString('gateway-ui');
    addTearDown(() => directory.delete(recursive: true));
    final store = GatewayConfigStore(configDirectory: directory.path);
    await store.savePrintProfile(
      StorePrintProfile(
        storeName: 'Local Shop',
        templateSettings: TemplateSettings(receiptTemplate: 'classic'),
      ),
      markLocalEdited: false,
    );
    final unsafeProfileJson = Map<String, Object?>.from(
      jsonDecode(await store.printProfileFile.readAsString()) as Map,
    );
    await store.printProfileFile.writeAsString(
      jsonEncode(<String, Object?>{
        ...unsafeProfileJson,
        'supabase_url': 'https://secret.example.test',
        'supabase_anon_key': 'anon-secret',
        'password': 'password-secret',
        'access_token': 'access-secret',
        'gateway_token': 'gateway-secret',
      }),
    );
    final server = GatewayWebServer(
      settings: const GatewayRuntimeSettings(
        supabaseUrl: 'https://control.example.test',
        supabaseAnonKey: 'compiled-anon-key',
        webPort: 0,
      ),
      store: store,
      webRoot: webRoot,
      snapshot: () => const GatewayRuntimeSnapshot(state: 'online'),
      onConfigurationChanged: () {},
    );
    await server.start();
    addTearDown(server.stop);

    final getResponse = await _get(server.boundPort, '/api/print-profile');
    final putResponse = await _put(
      server.boundPort,
      '/api/print-profile',
      <String, Object?>{
        'store_name': 'Edited Shop',
        'template_settings': <String, Object?>{
          'receipt_template': 'detailed',
          'kitchen_template': 'checklist',
          'languages': <String>['vi', 'ja', 'en'],
          'show_qr_code': true,
        },
      },
    );
    final saved = await store.loadPrintProfile();

    expect(getResponse.statusCode, HttpStatus.ok);
    expect(getResponse.body, contains('"store_name":"Local Shop"'));
    for (final secret in <String>[
      'secret.example.test',
      'anon-secret',
      'password-secret',
      'access-secret',
      'gateway-secret',
      'compiled-anon-key',
    ]) {
      expect(getResponse.body, isNot(contains(secret)));
      expect(putResponse.body, isNot(contains(secret)));
    }
    expect(putResponse.statusCode, HttpStatus.ok);
    expect(saved.storeName, 'Edited Shop');
    expect(saved.templateSettings.receiptTemplate, 'detailed');
    expect(saved.templateSettings.kitchenTemplate, 'checklist');
    expect(saved.templateSettings.languages, <String>['vi', 'ja', 'en']);
    expect(saved.localEditedAt, isNotNull);
  });

  test('print profile PUT rejects invalid input before saving', () async {
    final directory = await Directory.systemTemp.createTemp('airpos-invalid-');
    final webRoot = await Directory('${directory.path}/web').create();
    await File('${webRoot.path}/index.html').writeAsString('gateway-ui');
    addTearDown(() => directory.delete(recursive: true));
    final store = GatewayConfigStore(configDirectory: directory.path);
    await store.savePrintProfile(
      StorePrintProfile(storeName: 'Still Here'),
      markLocalEdited: false,
    );
    final server = GatewayWebServer(
      settings: const GatewayRuntimeSettings(
        supabaseUrl: 'https://control.example.test',
        supabaseAnonKey: 'compiled-anon-key',
        webPort: 0,
      ),
      store: store,
      webRoot: webRoot,
      snapshot: () => const GatewayRuntimeSnapshot(state: 'online'),
      onConfigurationChanged: () {},
    );
    await server.start();
    addTearDown(server.stop);

    final nonString = await _put(
      server.boundPort,
      '/api/print-profile',
      <String, Object?>{'store_name': 123},
    );
    final badTemplate = await _put(
      server.boundPort,
      '/api/print-profile',
      <String, Object?>{
        'template_settings': <String, Object?>{'receipt_template': 'unknown'},
      },
    );
    final badLanguage = await _put(
      server.boundPort,
      '/api/print-profile',
      <String, Object?>{
        'template_settings': <String, Object?>{
          'languages': <String>['vi', 'xx'],
        },
      },
    );
    final tooLong = await _put(
      server.boundPort,
      '/api/print-profile',
      <String, Object?>{'store_name': 'x' * 121},
    );

    expect(nonString.statusCode, HttpStatus.badRequest);
    expect(badTemplate.statusCode, HttpStatus.badRequest);
    expect(badLanguage.statusCode, HttpStatus.badRequest);
    expect(tooLong.statusCode, HttpStatus.badRequest);
    expect((await store.loadPrintProfile()).storeName, 'Still Here');
  });

  test('print profile sync detects local edits and force-syncs seed', () async {
    final directory = await Directory.systemTemp.createTemp('airpos-sync-');
    final webRoot = await Directory('${directory.path}/web').create();
    await File('${webRoot.path}/index.html').writeAsString('gateway-ui');
    addTearDown(() => directory.delete(recursive: true));
    final store = GatewayConfigStore(configDirectory: directory.path);
    await store.saveConfig(
      const GatewayConfig(
        tenantId: 'tenant-1',
        gatewayId: 'gateway-1',
        gatewayToken: 'gateway-token',
      ),
    );
    await store.savePrintProfile(StorePrintProfile(storeName: 'Local Edit'));
    var wakeCount = 0;
    final fake = _FakeControlPlaneClient(singleTenant: true);
    final server = GatewayWebServer(
      settings: const GatewayRuntimeSettings(
        supabaseUrl: 'https://control.example.test',
        supabaseAnonKey: 'compiled-anon-key',
        webPort: 0,
      ),
      store: store,
      webRoot: webRoot,
      snapshot: () => const GatewayRuntimeSnapshot(state: 'online'),
      onConfigurationChanged: () => wakeCount++,
      clientFactory: (_, {tenantId = '', gatewayId = '', gatewayToken = ''}) =>
          SupabaseGatewayClient(
            baseUrl: 'https://control.example.test',
            anonKey: 'compiled-anon-key',
            tenantId: tenantId,
            gatewayId: gatewayId,
            gatewayToken: gatewayToken,
            client: fake,
          ),
    );
    await server.start();
    addTearDown(server.stop);

    final conflict = await _post(
      server.boundPort,
      '/api/print-profile/sync',
      <String, Object?>{'replace_local': false},
    );
    final forced = await _post(
      server.boundPort,
      '/api/print-profile/sync',
      <String, Object?>{'replace_local': true},
    );
    final saved = await store.loadPrintProfile();

    expect(conflict.statusCode, HttpStatus.conflict);
    expect(conflict.body, contains('LOCAL_EDITS_EXIST'));
    expect(forced.statusCode, HttpStatus.ok);
    expect(fake.seedCalls, 1);
    expect(saved.storeName, 'Seed Store');
    expect(saved.templateSettings.receiptTemplate, 'compact');
    expect(saved.lastSyncedAt, isNotNull);
    expect(saved.localEditedAt, isNull);
    expect(wakeCount, 1);
  });

  test(
    'provision seed failure keeps login ok and clears old tenant profile',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'airpos-seedfail-',
      );
      final webRoot = await Directory('${directory.path}/web').create();
      await File('${webRoot.path}/index.html').writeAsString('gateway-ui');
      addTearDown(() => directory.delete(recursive: true));
      final store = GatewayConfigStore(configDirectory: directory.path);
      await store.savePrintProfile(
        StorePrintProfile(storeName: 'Previous Tenant'),
        markLocalEdited: false,
      );
      final fake = _FakeControlPlaneClient(singleTenant: true, failSeed: true);
      final server = GatewayWebServer(
        settings: const GatewayRuntimeSettings(
          supabaseUrl: 'https://control.example.test',
          supabaseAnonKey: 'compiled-anon-key',
          webPort: 0,
        ),
        store: store,
        webRoot: webRoot,
        snapshot: () => const GatewayRuntimeSnapshot(state: 'not_configured'),
        onConfigurationChanged: () {},
        clientFactory:
            (_, {tenantId = '', gatewayId = '', gatewayToken = ''}) =>
                SupabaseGatewayClient(
                  baseUrl: 'https://control.example.test',
                  anonKey: 'compiled-anon-key',
                  tenantId: tenantId,
                  gatewayId: gatewayId,
                  gatewayToken: gatewayToken,
                  client: fake,
                ),
      );
      await server.start();
      addTearDown(server.stop);

      final response = await _post(
        server.boundPort,
        '/api/auth/login',
        <String, Object?>{
          'email': 'owner@example.test',
          'password': 'password',
        },
      );
      final saved = await store.loadPrintProfile();

      expect(response.statusCode, HttpStatus.ok);
      expect(response.body, contains('"state":"provisioned"'));
      expect(response.body, isNot(contains('gateway-token')));
      expect(response.body, isNot(contains('supabase')));
      expect(saved.storeName, StorePrintProfile().storeName);
      expect(saved.storeName, isNot('Previous Tenant'));
      expect(saved.lastSyncedAt, isNull);
    },
  );

  test('print profile preview is local text only', () async {
    final directory = await Directory.systemTemp.createTemp('airpos-preview-');
    final webRoot = await Directory('${directory.path}/web').create();
    await File('${webRoot.path}/index.html').writeAsString('gateway-ui');
    addTearDown(() => directory.delete(recursive: true));
    final store = GatewayConfigStore(configDirectory: directory.path);
    await store.savePrintProfile(
      StorePrintProfile(
        storeName: 'Preview Shop',
        templateSettings: TemplateSettings(kitchenTemplate: 'checklist'),
      ),
      markLocalEdited: false,
    );
    final printerService = _RecordingPrinterService();
    final server = GatewayWebServer(
      settings: const GatewayRuntimeSettings(
        supabaseUrl: 'https://control.example.test',
        supabaseAnonKey: 'compiled-anon-key',
        webPort: 0,
      ),
      store: store,
      webRoot: webRoot,
      snapshot: () => const GatewayRuntimeSnapshot(state: 'online'),
      onConfigurationChanged: () {},
      printerService: printerService,
      clientFactory: (_, {tenantId = '', gatewayId = '', gatewayToken = ''}) =>
          throw StateError('network must not be used'),
    );
    await server.start();
    addTearDown(server.stop);

    final response = await _post(
      server.boundPort,
      '/api/print-profile/preview',
      <String, Object?>{'type': 'kitchen'},
    );
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;

    expect(response.statusCode, HttpStatus.ok);
    expect(decoded['type'], 'kitchen');
    expect(decoded['template'], 'checklist');
    expect(decoded['paper_width_mm'], 80);
    expect(decoded['text'], contains('KITCHEN CHECKLIST'));
    expect(printerService.previewCalls, 1);
    expect(printerService.connectionChecks, 0);
  });

  test(
    'printer test passes the saved local print profile to renderer flow',
    () async {
      final directory = await Directory.systemTemp.createTemp('airpos-test-');
      final webRoot = await Directory('${directory.path}/web').create();
      await File('${webRoot.path}/index.html').writeAsString('gateway-ui');
      addTearDown(() => directory.delete(recursive: true));

      final store = GatewayConfigStore(configDirectory: directory.path);
      await store.savePrinters(<PrinterProfile>[
        const PrinterProfile(
          id: 'printer-1',
          name: 'Receipt Printer',
          connectionType: ConnectionType.usb,
          protocol: PrinterProtocol.escpos,
          cupsQueue: 'Receipt',
        ),
      ]);
      final printProfile = StorePrintProfile(
        storeName: 'Local Template Store',
        templateSettings: TemplateSettings(receiptTemplate: 'classic'),
      );
      await store.savePrintProfile(printProfile, markLocalEdited: false);
      final printerService = _RecordingPrinterService();
      final server = GatewayWebServer(
        settings: const GatewayRuntimeSettings(
          supabaseUrl: 'https://control.example.test',
          supabaseAnonKey: 'compiled-anon-key',
          webPort: 0,
        ),
        store: store,
        webRoot: webRoot,
        snapshot: () => const GatewayRuntimeSnapshot(state: 'online'),
        onConfigurationChanged: () {},
        printerService: printerService,
      );
      await server.start();
      addTearDown(server.stop);

      final response = await _post(
        server.boundPort,
        '/api/printers/printer-1/test',
        <String, Object?>{'action': 'receipt'},
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(printerService.lastProfile?.id, 'printer-1');
      expect(printerService.lastAction, TestPrintAction.receipt);
      expect(
        printerService.lastPrintProfile?.storeName,
        printProfile.storeName,
      );
      expect(
        printerService.lastPrintProfile?.templateSettings.receiptTemplate,
        printProfile.templateSettings.receiptTemplate,
      );
    },
  );
}

Future<_Response> _get(int port, String path) async {
  final client = HttpClient();
  try {
    final request = await client.get('127.0.0.1', port, path);
    final response = await request.close();
    return _Response(
      response.statusCode,
      await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close(force: true);
  }
}

Future<_Response> _post(
  int port,
  String path,
  Map<String, Object?> body,
) async {
  final client = HttpClient();
  try {
    final request = await client.post('127.0.0.1', port, path);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    return _Response(
      response.statusCode,
      await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close(force: true);
  }
}

Future<_Response> _put(int port, String path, Map<String, Object?> body) async {
  final client = HttpClient();
  try {
    final request = await client.put('127.0.0.1', port, path);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    return _Response(
      response.statusCode,
      await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close(force: true);
  }
}

class _Response {
  const _Response(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

class _FakeControlPlaneClient extends http.BaseClient {
  _FakeControlPlaneClient({required this.singleTenant, this.failSeed = false});

  final bool singleTenant;
  final bool failSeed;
  int seedCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (path == '/rest/v1/rpc/print_gateway_get_store_print_seed') {
      seedCalls++;
      if (failSeed) {
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'message':
                    'supabase https://control.example.test gateway-token',
              }),
            ),
          ),
          HttpStatus.internalServerError,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
    }
    final body = switch (path) {
      '/auth/v1/token' => <String, Object?>{'access_token': 'access-token'},
      '/rest/v1/rpc/auth_get_my_tenants' => <String, Object?>{
        'tenants': <Map<String, String>>[
          <String, String>{
            'tenant_id': 'tenant-1',
            'slug': 'demo',
            'name': 'Demo shop',
            'role': 'owner',
          },
          if (!singleTenant)
            <String, String>{
              'tenant_id': 'tenant-2',
              'slug': 'second',
              'name': 'Second shop',
              'role': 'owner',
            },
        ],
      },
      '/rest/v1/rpc/print_register_gateway' => <String, Object?>{
        'gateway_id': 'gateway-1',
        'gateway_token': 'gateway-token',
        'poll_interval_sec': 5,
      },
      '/rest/v1/rpc/print_gateway_get_store_print_seed' => <String, Object?>{
        'store_settings': <String, Object?>{
          'store_name': 'Seed Store',
          'address': 'Tokyo',
          'phone': '03-0000-0000',
          'currency': 'JPY',
        },
        'receipt_settings': <String, Object?>{
          'receipt_template': 'compact',
          'kitchen_template': 'checklist',
          'languages': <String>['vi', 'ja'],
        },
      },
      _ => <String, Object?>{},
    };
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      HttpStatus.ok,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
}

class _RecordingPrinterService extends GatewayPrinterService {
  PrinterProfile? lastProfile;
  TestPrintAction? lastAction;
  StorePrintProfile? lastPrintProfile;
  int previewCalls = 0;
  int connectionChecks = 0;

  @override
  Future<PrinterCapabilities> probeCapabilities(PrinterProfile profile) async {
    return const PrinterCapabilities();
  }

  @override
  Future<PrinterHealth> testConnection(PrinterProfile profile) async {
    connectionChecks++;
    return const PrinterHealth(status: PrinterHealthStatus.connected);
  }

  @override
  String previewText({required String type, StorePrintProfile? printProfile}) {
    previewCalls++;
    return super.previewText(type: type, printProfile: printProfile);
  }

  @override
  Future<void> test(
    PrinterProfile profile,
    TestPrintAction action, {
    StorePrintProfile? printProfile,
  }) async {
    lastProfile = profile;
    lastAction = action;
    lastPrintProfile = printProfile;
  }
}
