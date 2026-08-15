import 'dart:async';
import 'dart:io';

import 'config_store.dart';
import 'gateway_api.dart';
import 'runtime_settings.dart';
import 'runtime_status.dart';
import 'web_server.dart';
import 'worker.dart';

class GatewayRuntime {
  GatewayRuntime({
    required this.settings,
    required this.store,
    required this.webRoot,
    GatewayPrinterService? printerService,
    void Function(String message)? log,
  }) : _printerService = printerService ?? GatewayPrinterService(),
       _log = log ?? print;

  final GatewayRuntimeSettings settings;
  final GatewayConfigStore store;
  final Directory webRoot;
  final GatewayPrinterService _printerService;
  final void Function(String message) _log;

  GatewayWebServer? _webServer;
  Timer? _timer;
  DateTime _nextRun = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false;
  bool _stopped = false;
  GatewayRuntimeSnapshot _snapshot = const GatewayRuntimeSnapshot(
    state: 'starting',
  );

  GatewayRuntimeSnapshot get snapshot => _snapshot;

  Future<void> start() async {
    _stopped = false;
    _webServer = GatewayWebServer(
      settings: settings,
      store: store,
      webRoot: webRoot,
      snapshot: () => _snapshot,
      onConfigurationChanged: wake,
    );
    await _webServer!.start();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_tick());
    });
    await _tick();
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _webServer?.stop();
    _webServer = null;
  }

  void wake() {
    _nextRun = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(_tick());
  }

  Future<void> _tick() async {
    if (_stopped || _busy || DateTime.now().isBefore(_nextRun)) return;
    _busy = true;
    try {
      final config = await store.loadConfig();
      if (config == null || !config.isProvisioned) {
        _snapshot = const GatewayRuntimeSnapshot(state: 'not_configured');
        _nextRun = DateTime.now().add(const Duration(seconds: 2));
        return;
      }

      final printers = await store.loadPrinters();
      final printProfile = await store.loadPrintProfile();
      final api = SupabaseGatewayClient.fromSettings(
        settings,
        tenantId: config.tenantId,
        gatewayId: config.gatewayId,
        gatewayToken: config.gatewayToken,
      );
      try {
        final worker = GatewayWorker(
          config: config,
          printers: printers,
          api: api,
          printProfile: printProfile,
          printerService: _printerService,
          log: _log,
        );
        final jobs = await worker.runOnce();
        _snapshot = GatewayRuntimeSnapshot(
          state: 'online',
          lastHeartbeatAt: DateTime.now(),
          lastJobCount: jobs,
        );
        _nextRun = DateTime.now().add(
          Duration(seconds: config.pollIntervalSeconds.clamp(1, 60)),
        );
      } finally {
        api.close();
      }
    } catch (error) {
      final safe = _safeMessage(error);
      _snapshot = GatewayRuntimeSnapshot(
        state: 'error',
        lastHeartbeatAt: _snapshot.lastHeartbeatAt,
        lastJobCount: _snapshot.lastJobCount,
        lastError: safe,
      );
      _log('runtime error: $safe');
      _nextRun = DateTime.now().add(const Duration(seconds: 5));
    } finally {
      _busy = false;
    }
  }
}

String _safeMessage(Object error) {
  if (error is GatewayApiException && error.message.contains('Bearer')) {
    return 'Control plane request failed (${error.statusCode}).';
  }
  return error.toString().replaceAll(
    RegExp(r'(token|password|secret)\s*[:=]\s*\S+', caseSensitive: false),
    r'$1=[redacted]',
  );
}
