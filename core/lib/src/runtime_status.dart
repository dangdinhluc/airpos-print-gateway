class GatewayRuntimeSnapshot {
  const GatewayRuntimeSnapshot({
    required this.state,
    this.lastHeartbeatAt,
    this.lastJobCount = 0,
    this.lastError,
  });

  final String state;
  final DateTime? lastHeartbeatAt;
  final int lastJobCount;
  final String? lastError;

  Map<String, Object?> toJson() => <String, Object?>{
    'state': state,
    'last_heartbeat_at': lastHeartbeatAt?.toUtc().toIso8601String(),
    'last_job_count': lastJobCount,
    'last_error': lastError,
  };
}
