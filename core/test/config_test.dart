import 'dart:convert';
import 'dart:io';

import 'package:airpos_print_gateway_core/airpos_print_gateway_core.dart';
import 'package:test/test.dart';

void main() {
  test('migrates legacy config without retaining Supabase fields', () async {
    final directory = await Directory.systemTemp.createTemp('airpos-config-');
    addTearDown(() => directory.delete(recursive: true));
    final store = GatewayConfigStore(configDirectory: directory.path);
    await store.configFile.writeAsString(
      jsonEncode(<String, Object?>{
        'base_url': 'https://secret.example.test',
        'anon_key': 'legacy-anon-key',
        'tenant_id': 'tenant-1',
        'gateway_id': 'gateway-1',
        'gateway_token': 'gateway-token',
      }),
    );

    final config = await store.loadConfig();
    final migrated = jsonDecode(await store.configFile.readAsString());

    expect(config?.isProvisioned, isTrue);
    expect(migrated, isNot(contains('base_url')));
    expect(migrated, isNot(contains('anon_key')));
    expect(migrated['gateway_token'], 'gateway-token');
  });

  test('runtime settings require compiled control-plane values', () {
    expect(
      const GatewayRuntimeSettings(
        supabaseUrl: '',
        supabaseAnonKey: '',
      ).isConfigured,
      isFalse,
    );
    expect(
      () => const GatewayRuntimeSettings(
        supabaseUrl: '',
        supabaseAnonKey: '',
      ).requireConfigured(),
      throwsStateError,
    );
  });
}
