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
        clientFactory: (_) => SupabaseGatewayClient(
          baseUrl: 'https://control.example.test',
          anonKey: 'compiled-anon-key',
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

class _Response {
  const _Response(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

class _FakeControlPlaneClient extends http.BaseClient {
  _FakeControlPlaneClient({required this.singleTenant});

  final bool singleTenant;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
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
