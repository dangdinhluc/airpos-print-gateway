import 'dart:convert';

import 'package:airpos_print_gateway_core/airpos_print_gateway_core.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  test('sends printer metadata with the Linux heartbeat', () async {
    final client = _RecordingClient();
    final api = SupabaseGatewayClient(
      baseUrl: 'https://control.example.test',
      anonKey: 'anon-key',
      tenantId: 'tenant-1',
      gatewayId: 'gateway-1',
      gatewayToken: 'gateway-token',
      client: client,
    );

    final result = await api.heartbeat(
      'ubuntu-2.0.5',
      metadata: <String, Object?>{
        'platform': 'ubuntu',
        'local_printers': <Map<String, Object?>>[
          <String, Object?>{'id': 'receipt-usb', 'role': 'pos'},
        ],
      },
    );

    expect(result.ok, isTrue);
    expect(client.path, '/rest/v1/rpc/print_gateway_heartbeat');
    expect(client.body['p_app_version'], 'ubuntu-2.0.5');
    expect(client.body['p_metadata'], <String, Object?>{
      'platform': 'ubuntu',
      'local_printers': <Map<String, Object?>>[
        <String, Object?>{'id': 'receipt-usb', 'role': 'pos'},
      ],
    });
  });

  test('fetches print seed with gateway credentials', () async {
    final client = _RecordingClient(
      response: <String, Object?>{
        'store_settings': <String, Object?>{'store_name': 'Seed Store'},
      },
    );
    final api = SupabaseGatewayClient(
      baseUrl: 'https://control.example.test',
      anonKey: 'anon-key',
      tenantId: 'tenant-1',
      gatewayId: 'gateway-1',
      gatewayToken: 'gateway-token',
      client: client,
    );

    final result = await api.fetchStorePrintSeed();

    expect(client.path, '/rest/v1/rpc/print_gateway_get_store_print_seed');
    expect(client.body, <String, Object?>{
      'p_tenant_id': 'tenant-1',
      'p_gateway_id': 'gateway-1',
      'p_gateway_token': 'gateway-token',
    });
    expect(result['store_settings']['store_name'], 'Seed Store');
  });
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient({this.response = const <String, Object?>{}});

  final Map<String, Object?> response;
  String path = '';
  Map<String, dynamic> body = <String, dynamic>{};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final typedRequest = request as http.Request;
    path = typedRequest.url.path;
    body = Map<String, dynamic>.from(jsonDecode(typedRequest.body) as Map);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(response))),
      200,
      request: request,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
}
