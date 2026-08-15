import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'runtime_settings.dart';

class GatewayApiException implements Exception {
  const GatewayApiException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String? code;
  final String message;

  @override
  String toString() => message;
}

class GatewayHeartbeatResult {
  const GatewayHeartbeatResult({required this.ok, this.detail});

  final bool ok;
  final String? detail;
}

class SupabaseGatewayClient {
  SupabaseGatewayClient({
    required String baseUrl,
    required this.anonKey,
    this.tenantId = '',
    this.gatewayId = '',
    this.gatewayToken = '',
    http.Client? client,
  }) : baseUrl = baseUrl.trim().replaceFirst(RegExp(r'/+$'), ''),
       _client = client ?? http.Client();

  factory SupabaseGatewayClient.fromSettings(
    GatewayRuntimeSettings settings, {
    String tenantId = '',
    String gatewayId = '',
    String gatewayToken = '',
    http.Client? client,
  }) {
    settings.requireConfigured();
    return SupabaseGatewayClient(
      baseUrl: settings.supabaseUrl,
      anonKey: settings.supabaseAnonKey,
      tenantId: tenantId,
      gatewayId: gatewayId,
      gatewayToken: gatewayToken,
      client: client,
    );
  }

  final String baseUrl;
  final String anonKey;
  final String tenantId;
  final String gatewayId;
  final String gatewayToken;
  final http.Client _client;

  void close() => _client.close();

  Future<GatewayLoginResult> loginAndFetchTenants(
    String email,
    String password,
  ) async {
    final login = await _request(
      Uri.parse('$baseUrl/auth/v1/token?grant_type=password'),
      body: <String, Object?>{
        'email': email.trim().toLowerCase(),
        'password': password,
      },
      authorization: anonKey,
    );
    final accessToken = _string(login['access_token']);
    if (accessToken.isEmpty) {
      throw const GatewayApiException(
        0,
        'NO_TOKEN',
        'Login did not return access_token.',
      );
    }
    final tenantsBody = await _request(
      Uri.parse('$baseUrl/rest/v1/rpc/auth_get_my_tenants'),
      body: const <String, Object?>{},
      authorization: accessToken,
    );
    final rawTenants = tenantsBody['tenants'];
    final tenants = rawTenants is List
        ? rawTenants
              .whereType<Map<Object?, Object?>>()
              .map(
                (item) =>
                    TenantOption.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((tenant) => tenant.tenantId.isNotEmpty)
              .toList(growable: false)
        : <TenantOption>[];
    return GatewayLoginResult(accessToken: accessToken, tenants: tenants);
  }

  Future<GatewayProvisionResult> registerGateway({
    required String accessToken,
    required String selectedTenantId,
    required String gatewayName,
    required String fingerprint,
    String appVersion = 'ubuntu-2.0.0',
  }) async {
    final response = await _request(
      Uri.parse('$baseUrl/rest/v1/rpc/print_register_gateway'),
      body: <String, Object?>{
        'p_tenant_id': selectedTenantId.trim(),
        'p_name': gatewayName.trim().isEmpty
            ? 'Ubuntu Print Gateway'
            : gatewayName.trim(),
        'p_fingerprint': fingerprint.trim(),
        'p_area_id': null,
        'p_app_version': appVersion,
        'p_metadata': <String, Object?>{'platform': 'ubuntu'},
      },
      authorization: accessToken,
    );
    final gatewayId = _string(response['gateway_id']);
    final token = _string(response['gateway_token']).isEmpty
        ? _string(response['token'])
        : _string(response['gateway_token']);
    if (gatewayId.isEmpty || token.isEmpty) {
      throw const GatewayApiException(
        0,
        'INVALID_GATEWAY_RESPONSE',
        'Gateway registration did not return credentials.',
      );
    }
    return GatewayProvisionResult(
      gatewayId: gatewayId,
      gatewayToken: token,
      pollIntervalSeconds: _number(
        response['poll_interval_sec'],
        5,
      ).clamp(1, 60),
    );
  }

  Future<GatewayHeartbeatResult> validateConnection() async {
    try {
      await _request(
        Uri.parse('$baseUrl/rest/v1/rpc/app_healthcheck'),
        body: const <String, Object?>{},
        authorization: anonKey,
      );
      return const GatewayHeartbeatResult(ok: true);
    } catch (error) {
      return GatewayHeartbeatResult(ok: false, detail: error.toString());
    }
  }

  Future<GatewayHeartbeatResult> heartbeat(
    String appVersion, {
    Map<String, Object?> metadata = const <String, Object?>{
      'platform': 'ubuntu',
    },
  }) async {
    try {
      await _rpc('print_gateway_heartbeat', <String, Object?>{
        'p_tenant_id': tenantId,
        'p_gateway_id': gatewayId,
        'p_gateway_token': gatewayToken,
        'p_app_version': appVersion,
        'p_metadata': metadata,
      });
      return const GatewayHeartbeatResult(ok: true);
    } catch (error) {
      return GatewayHeartbeatResult(ok: false, detail: error.toString());
    }
  }

  Future<List<GatewayJob>> claimNextJobs({int limit = 20}) async {
    final jobs = <GatewayJob>[];
    for (var index = 0; index < limit.clamp(1, 50); index++) {
      final response = await _rpc(
        'print_gateway_claim_next_job',
        <String, Object?>{
          'p_tenant_id': tenantId,
          'p_gateway_id': gatewayId,
          'p_gateway_token': gatewayToken,
          'p_job_types': const <String>[
            'receipt',
            'draft_receipt',
            'kitchen_ticket',
            'table_qr',
            'cash_drawer',
          ],
        },
      );
      if (response == null || response.isEmpty) break;
      final job = GatewayJob.fromJson(response);
      if (job.id.isEmpty) break;
      jobs.add(job);
    }
    return jobs;
  }

  Future<void> ackSuccess(String jobId, Duration duration) =>
      _ack(jobId, 'printed', 'duration_ms=${duration.inMilliseconds}');

  Future<void> ackFailure(
    String jobId,
    String errorCode,
    String message,
    Duration duration,
  ) {
    return _ack(
      jobId,
      'failed',
      '${errorCode.trim()} | ${message.trim()} | duration_ms=${duration.inMilliseconds}',
    );
  }

  Future<int> recoverStuckClaims({int ageSeconds = 180}) async {
    final response =
        await _rpc('print_gateway_recover_stuck_claims', <String, Object?>{
          'p_tenant_id': tenantId,
          'p_gateway_id': gatewayId,
          'p_gateway_token': gatewayToken,
          'p_claim_age_seconds': ageSeconds.clamp(60, 3600),
        });
    return _number(response?['recovered_count'], 0);
  }

  Future<Map<String, dynamic>> fetchStorePrintSeed() async {
    return await _rpc('print_gateway_get_store_print_seed', <String, Object?>{
          'p_tenant_id': tenantId,
          'p_gateway_id': gatewayId,
          'p_gateway_token': gatewayToken,
        }) ??
        <String, dynamic>{};
  }

  Future<void> _ack(String jobId, String status, String error) async {
    await _rpc('print_gateway_ack_job', <String, Object?>{
      'p_job_id': jobId,
      'p_gateway_id': gatewayId,
      'p_gateway_token': gatewayToken,
      'p_status': status,
      'p_error': error,
    });
  }

  Future<Map<String, dynamic>?> _rpc(
    String function,
    Map<String, Object?> body,
  ) async {
    final response = await _request(
      Uri.parse('$baseUrl/rest/v1/rpc/$function'),
      body: body,
      authorization: anonKey,
    );
    return response;
  }

  Future<Map<String, dynamic>> _request(
    Uri uri, {
    required Map<String, Object?> body,
    required String authorization,
  }) async {
    if (baseUrl.isEmpty) {
      throw const GatewayApiException(
        0,
        'SUPABASE_URL_REQUIRED',
        'Supabase URL is required.',
      );
    }
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (anonKey.trim().isNotEmpty) 'apikey': anonKey.trim(),
      if (authorization.trim().isNotEmpty)
        'Authorization': 'Bearer ${authorization.trim()}',
    };
    final response = await _client
        .post(uri, headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    final decoded = _decode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GatewayApiException(
        response.statusCode,
        _string(decoded['code']).isEmpty ? null : _string(decoded['code']),
        _string(decoded['message']).isEmpty
            ? (_string(decoded['hint']).isEmpty
                  ? 'HTTP ${response.statusCode}'
                  : _string(decoded['hint']))
            : _string(decoded['message']),
      );
    }
    return decoded;
  }

  Map<String, dynamic> _decode(String raw) {
    if (raw.trim().isEmpty || raw.trim() == 'null') return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
        return Map<String, dynamic>.from(decoded.first as Map);
      }
    } on FormatException {
      // Error text is retained by _request as a generic HTTP failure.
    }
    return <String, dynamic>{};
  }
}

String _string(Object? value) => value?.toString().trim() ?? '';

int _number(Object? value, int fallback) => switch (value) {
  int value => value,
  num value => value.round(),
  String value => int.tryParse(value.trim()) ?? fallback,
  _ => fallback,
};
