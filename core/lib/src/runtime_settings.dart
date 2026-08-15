class GatewayRuntimeSettings {
  const GatewayRuntimeSettings({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    this.appVersion = 'ubuntu-2.0.0',
    this.webHost = '127.0.0.1',
    this.webPort = 20128,
  });

  factory GatewayRuntimeSettings.fromEnvironment() {
    return const GatewayRuntimeSettings(
      supabaseUrl: String.fromEnvironment('AIRPOS_SUPABASE_URL'),
      supabaseAnonKey: String.fromEnvironment('AIRPOS_SUPABASE_ANON_KEY'),
      appVersion: String.fromEnvironment(
        'AIRPOS_GATEWAY_APP_VERSION',
        defaultValue: 'ubuntu-2.0.0',
      ),
    );
  }

  final String supabaseUrl;
  final String supabaseAnonKey;
  final String appVersion;
  final String webHost;
  final int webPort;

  bool get isConfigured =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;

  void requireConfigured() {
    if (!isConfigured) {
      throw StateError(
        'Gateway runtime is missing its compiled control-plane configuration.',
      );
    }
  }
}
