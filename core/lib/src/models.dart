import 'dart:convert';

enum ConnectionType { network, usb, bluetooth }

extension ConnectionTypeValue on ConnectionType {
  String get value => name;

  static ConnectionType parse(Object? value) {
    return switch (value?.toString().trim().toLowerCase()) {
      'usb' => ConnectionType.usb,
      'bluetooth' || 'bt' => ConnectionType.bluetooth,
      _ => ConnectionType.network,
    };
  }
}

enum PrinterProtocol { escpos, starCups }

extension PrinterProtocolValue on PrinterProtocol {
  String get value => this == PrinterProtocol.starCups ? 'star_cups' : 'escpos';

  static PrinterProtocol parse(Object? value) {
    return switch (value?.toString().trim().toLowerCase()) {
      'star' || 'star_cups' || 'starcups' => PrinterProtocol.starCups,
      _ => PrinterProtocol.escpos,
    };
  }
}

enum PrinterHealthStatus {
  connected,
  queueMissing,
  permissionDenied,
  driverMissing,
  printerError,
  unavailable,
}

extension PrinterHealthStatusValue on PrinterHealthStatus {
  String get value => name;
}

class PrinterCapabilities {
  const PrinterCapabilities({
    this.raster = true,
    this.text = true,
    this.image = true,
    this.qr = true,
    this.cut = true,
    this.beep = true,
    this.cashDrawer = true,
    this.warning,
  });

  final bool raster;
  final bool text;
  final bool image;
  final bool qr;
  final bool cut;
  final bool beep;
  final bool cashDrawer;
  final String? warning;

  Map<String, Object?> toJson() => <String, Object?>{
    'raster': raster,
    'text': text,
    'image': image,
    'qr': qr,
    'cut': cut,
    'beep': beep,
    'cash_drawer': cashDrawer,
    'warning': warning,
  };

  factory PrinterCapabilities.fromJson(Map<String, dynamic> json) {
    return PrinterCapabilities(
      raster: json['raster'] as bool? ?? true,
      text: json['text'] as bool? ?? true,
      image: json['image'] as bool? ?? true,
      qr: json['qr'] as bool? ?? true,
      cut: json['cut'] as bool? ?? true,
      beep: json['beep'] as bool? ?? true,
      cashDrawer: json['cash_drawer'] as bool? ?? true,
      warning: (json['warning'] as String?)?.trim().isEmpty == true
          ? null
          : json['warning'] as String?,
    );
  }

  PrinterCapabilities copyWith({
    bool? raster,
    bool? text,
    bool? image,
    bool? qr,
    bool? cut,
    bool? beep,
    bool? cashDrawer,
    String? warning,
    bool replaceWarning = false,
  }) {
    return PrinterCapabilities(
      raster: raster ?? this.raster,
      text: text ?? this.text,
      image: image ?? this.image,
      qr: qr ?? this.qr,
      cut: cut ?? this.cut,
      beep: beep ?? this.beep,
      cashDrawer: cashDrawer ?? this.cashDrawer,
      warning: replaceWarning ? warning : warning ?? this.warning,
    );
  }
}

PrinterCapabilities defaultCapabilities(
  ConnectionType connection,
  PrinterProtocol protocol,
) {
  if (protocol == PrinterProtocol.starCups) {
    return const PrinterCapabilities(
      raster: true,
      text: false,
      image: true,
      qr: true,
      cut: true,
      beep: false,
      cashDrawer: true,
      warning:
          'Star CUPS driver capability is model-dependent; buzzer is disabled until declared by the driver.',
    );
  }
  return const PrinterCapabilities();
}

class PrinterProfile {
  const PrinterProfile({
    required this.id,
    required this.name,
    required this.connectionType,
    required this.protocol,
    this.host,
    this.port = 9100,
    this.bluetoothAddress,
    this.cupsQueue,
    this.cupsDeviceUri,
    this.printerModel = '',
    this.role = 'receipt',
    this.area = '',
    this.station = '',
    this.paperWidthMm = 80,
    this.cut = true,
    this.beep = false,
    this.cashDrawer = false,
    PrinterCapabilities? capabilities,
    this.enabled = true,
  }) : capabilities = capabilities ?? const PrinterCapabilities();

  final String id;
  final String name;
  final ConnectionType connectionType;
  final PrinterProtocol protocol;
  final String? host;
  final int port;
  final String? bluetoothAddress;
  final String? cupsQueue;
  final String? cupsDeviceUri;
  final String printerModel;
  final String role;
  final String area;
  final String station;
  final int paperWidthMm;
  final bool cut;
  final bool beep;
  final bool cashDrawer;
  final PrinterCapabilities capabilities;
  final bool enabled;

  bool get isUsb => connectionType == ConnectionType.usb;

  bool get usesCups =>
      isUsb ||
      connectionType == ConnectionType.bluetooth ||
      protocol == PrinterProtocol.starCups;

  PrinterCapabilities get effectiveCapabilities =>
      capabilities == const PrinterCapabilities()
      ? defaultCapabilities(connectionType, protocol)
      : capabilities;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'connection_type': connectionType.value,
    'protocol': protocol.value,
    'host': host,
    'port': port,
    'bluetooth_address': bluetoothAddress,
    'cups_queue': cupsQueue,
    'cups_device_uri': cupsDeviceUri,
    'printer_model': printerModel,
    'role': role,
    'area': area,
    'station': station,
    'paper_width_mm': paperWidthMm,
    'cut': cut,
    'beep': beep,
    'cash_drawer': cashDrawer,
    'capabilities': effectiveCapabilities.toJson(),
    'enabled': enabled,
  };

  factory PrinterProfile.fromJson(Map<String, dynamic> json) {
    final connection = ConnectionTypeValue.parse(json['connection_type']);
    final protocol = PrinterProtocolValue.parse(json['protocol']);
    final rawCapabilities = json['capabilities'];
    return PrinterProfile(
      id: _string(json['id']).isEmpty ? _stableId(json) : _string(json['id']),
      name: _string(json['name']).isEmpty ? 'Printer' : _string(json['name']),
      connectionType: connection,
      protocol: protocol,
      host: _nullableString(json['host']),
      port: _int(json['port'], 9100).clamp(1, 65535),
      bluetoothAddress: _nullableString(json['bluetooth_address']),
      cupsQueue: _nullableString(json['cups_queue']),
      cupsDeviceUri: _nullableString(json['cups_device_uri']),
      printerModel: _string(json['printer_model']),
      role: _string(json['role']).isEmpty ? 'receipt' : _string(json['role']),
      area: _string(json['area']),
      station: _string(json['station']),
      paperWidthMm: _int(json['paper_width_mm'], 80) == 58 ? 58 : 80,
      cut: json['cut'] as bool? ?? true,
      beep: json['beep'] as bool? ?? false,
      cashDrawer: json['cash_drawer'] as bool? ?? false,
      capabilities: rawCapabilities is Map
          ? PrinterCapabilities.fromJson(
              Map<String, dynamic>.from(rawCapabilities),
            )
          : defaultCapabilities(connection, protocol),
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  PrinterProfile copyWith({
    String? id,
    String? name,
    ConnectionType? connectionType,
    PrinterProtocol? protocol,
    String? host,
    int? port,
    String? bluetoothAddress,
    String? cupsQueue,
    String? cupsDeviceUri,
    String? printerModel,
    String? role,
    String? area,
    String? station,
    int? paperWidthMm,
    bool? cut,
    bool? beep,
    bool? cashDrawer,
    PrinterCapabilities? capabilities,
    bool? enabled,
  }) {
    return PrinterProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      connectionType: connectionType ?? this.connectionType,
      protocol: protocol ?? this.protocol,
      host: host ?? this.host,
      port: port ?? this.port,
      bluetoothAddress: bluetoothAddress ?? this.bluetoothAddress,
      cupsQueue: cupsQueue ?? this.cupsQueue,
      cupsDeviceUri: cupsDeviceUri ?? this.cupsDeviceUri,
      printerModel: printerModel ?? this.printerModel,
      role: role ?? this.role,
      area: area ?? this.area,
      station: station ?? this.station,
      paperWidthMm: paperWidthMm ?? this.paperWidthMm,
      cut: cut ?? this.cut,
      beep: beep ?? this.beep,
      cashDrawer: cashDrawer ?? this.cashDrawer,
      capabilities: capabilities ?? this.capabilities,
      enabled: enabled ?? this.enabled,
    );
  }
}

class GatewayConfig {
  const GatewayConfig({
    required this.tenantId,
    required this.gatewayId,
    required this.gatewayToken,
    this.pollIntervalSeconds = 5,
    this.appVersion = 'ubuntu-2.0.0',
  });

  final String tenantId;
  final String gatewayId;
  final String gatewayToken;
  final int pollIntervalSeconds;
  final String appVersion;

  bool get isProvisioned =>
      tenantId.isNotEmpty && gatewayId.isNotEmpty && gatewayToken.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'tenant_id': tenantId,
    'gateway_id': gatewayId,
    'gateway_token': gatewayToken,
    'poll_interval_seconds': pollIntervalSeconds,
    'app_version': appVersion,
  };

  factory GatewayConfig.fromJson(Map<String, dynamic> json) {
    return GatewayConfig(
      tenantId: _string(json['tenant_id']),
      gatewayId: _string(json['gateway_id']),
      gatewayToken: _string(json['gateway_token']),
      pollIntervalSeconds: _int(json['poll_interval_seconds'], 5).clamp(1, 60),
      appVersion: _string(json['app_version']).isEmpty
          ? 'ubuntu-2.0.0'
          : _string(json['app_version']),
    );
  }
}

class GatewayJob {
  const GatewayJob({
    required this.id,
    required this.jobType,
    required this.payload,
    this.orderId,
    this.createdAt,
  });

  final String id;
  final String jobType;
  final Map<String, dynamic> payload;
  final String? orderId;
  final String? createdAt;

  factory GatewayJob.fromJson(Map<String, dynamic> json) {
    final rawPayload = json['payload'];
    Map<String, dynamic> payload = <String, dynamic>{};
    if (rawPayload is Map) {
      payload = Map<String, dynamic>.from(rawPayload);
    } else if (rawPayload is String && rawPayload.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPayload);
        if (decoded is Map) payload = Map<String, dynamic>.from(decoded);
      } on FormatException {
        payload = <String, dynamic>{};
      }
    }
    return GatewayJob(
      id: _string(json['id']),
      jobType: _string(json['job_type']).toLowerCase(),
      payload: payload,
      orderId: _nullableString(json['order_id']),
      createdAt: _nullableString(json['created_at']),
    );
  }
}

class TenantOption {
  const TenantOption({
    required this.tenantId,
    required this.slug,
    required this.name,
    required this.role,
  });

  final String tenantId;
  final String slug;
  final String name;
  final String role;

  factory TenantOption.fromJson(Map<String, dynamic> json) => TenantOption(
    tenantId: _string(json['tenant_id']),
    slug: _string(json['slug']),
    name: _string(json['name']).isEmpty ? 'Unknown' : _string(json['name']),
    role: _string(json['role']),
  );
}

class GatewayLoginResult {
  const GatewayLoginResult({required this.accessToken, required this.tenants});

  final String accessToken;
  final List<TenantOption> tenants;
}

class GatewayProvisionResult {
  const GatewayProvisionResult({
    required this.gatewayId,
    required this.gatewayToken,
    required this.pollIntervalSeconds,
  });

  final String gatewayId;
  final String gatewayToken;
  final int pollIntervalSeconds;
}

class PrinterHealth {
  const PrinterHealth({required this.status, this.detail});

  final PrinterHealthStatus status;
  final String? detail;
}

class CupsPrintResult {
  const CupsPrintResult({required this.requestId});

  final String requestId;
}

String _string(Object? value) => value?.toString().trim() ?? '';

String? _nullableString(Object? value) {
  final result = _string(value);
  return result.isEmpty ? null : result;
}

int _int(Object? value, int fallback) => switch (value) {
  int value => value,
  num value => value.round(),
  String value => int.tryParse(value.trim()) ?? fallback,
  _ => fallback,
};

String _stableId(Map<String, dynamic> json) {
  final seed = <String>[
    _string(json['name']),
    _string(json['cups_queue']),
    _string(json['cups_device_uri']),
    _string(json['host']),
  ].where((value) => value.isNotEmpty).join('-');
  return seed.isEmpty
      ? 'printer-${DateTime.now().microsecondsSinceEpoch}'
      : seed;
}
