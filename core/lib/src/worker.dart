import 'dart:async';
import 'dart:io';

import 'cups.dart';
import 'escpos.dart';
import 'gateway_api.dart';
import 'models.dart';

class GatewayPrinterService {
  GatewayPrinterService({
    CupsPrintTransport? cups,
    GatewayPrintRenderer? renderer,
  }) : _cups = cups ?? CupsPrintTransport(),
       _renderer = renderer ?? const GatewayPrintRenderer();

  final CupsPrintTransport _cups;
  final GatewayPrintRenderer _renderer;

  Future<void> printJob(GatewayJob job, PrinterProfile profile) async {
    final effective = profile.copyWith(
      capabilities: await probeCapabilities(profile),
    );
    final document = await _renderer.renderJob(job, effective);
    await _send(effective, document);
  }

  Future<void> test(PrinterProfile profile, TestPrintAction action) async {
    final effective = profile.copyWith(
      capabilities: await probeCapabilities(profile),
    );
    final document = await _renderer.renderTest(effective, action: action);
    await _send(effective, document);
  }

  Future<PrinterHealth> testConnection(PrinterProfile profile) async {
    if (profile.usesCups) {
      return CupsPrinterStatusService().inspect(profile);
    }
    final host = profile.host?.trim() ?? '';
    if (host.isEmpty) {
      return const PrinterHealth(
        status: PrinterHealthStatus.unavailable,
        detail: 'Network printer IP/host chưa được cấu hình.',
      );
    }
    try {
      final socket = await Socket.connect(
        host,
        profile.port,
        timeout: const Duration(seconds: 4),
      );
      await socket.close();
      return const PrinterHealth(status: PrinterHealthStatus.connected);
    } catch (error) {
      return PrinterHealth(
        status: PrinterHealthStatus.printerError,
        detail: error.toString(),
      );
    }
  }

  Future<PrinterCapabilities> probeCapabilities(PrinterProfile profile) {
    return profile.usesCups
        ? CupsPrinterStatusService().probeCapabilities(profile)
        : Future<PrinterCapabilities>.value(profile.effectiveCapabilities);
  }

  Future<void> _send(PrinterProfile profile, RenderedDocument document) async {
    if (profile.usesCups) {
      await _cups.print(
        profile,
        document.bytes,
        options: document.cupsOptions,
        raw: document.raw,
      );
      return;
    }
    final host = profile.host?.trim() ?? '';
    if (host.isEmpty) {
      throw const CupsException(
        PrinterHealthStatus.unavailable,
        'Network printer IP/host chưa được cấu hình.',
      );
    }
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        profile.port,
        timeout: const Duration(seconds: 5),
      );
      socket.add(document.bytes);
      await socket.flush();
    } finally {
      await socket?.close();
    }
  }
}

class GatewayWorker {
  GatewayWorker({
    required this.config,
    required this.printers,
    required SupabaseGatewayClient api,
    GatewayPrinterService? printerService,
    void Function(String message)? log,
  }) : _api = api,
       _printerService = printerService ?? GatewayPrinterService(),
       _log = log ?? print;

  final GatewayConfig config;
  final List<PrinterProfile> printers;
  final SupabaseGatewayClient _api;
  final GatewayPrinterService _printerService;
  final void Function(String message) _log;

  Future<void> runForever() async {
    while (true) {
      try {
        await runOnce();
      } catch (error) {
        _log('worker error: ${_safeMessage(error)}');
      }
      await Future<void>.delayed(
        Duration(seconds: config.pollIntervalSeconds.clamp(1, 60)),
      );
    }
  }

  Future<int> runOnce() async {
    if (!config.isProvisioned) {
      throw StateError(
        'Gateway chưa được provision; mở GUI để đăng ký gateway.',
      );
    }
    final heartbeat = await _api.heartbeat(config.appVersion);
    if (!heartbeat.ok) {
      throw StateError('heartbeat failed: ${heartbeat.detail ?? 'unknown'}');
    }
    try {
      final recovered = await _api.recoverStuckClaims();
      if (recovered > 0) _log('recovered $recovered stuck print jobs');
    } catch (error) {
      _log('recover skipped: ${_safeMessage(error)}');
    }
    final jobs = await _api.claimNextJobs();
    for (final job in jobs) {
      await _process(job);
    }
    return jobs.length;
  }

  Future<void> _process(GatewayJob job) async {
    final started = DateTime.now();
    try {
      final profile = _selectProfile(job);
      await _printerService.printJob(job, profile);
    } catch (error) {
      final duration = DateTime.now().difference(started);
      try {
        await _api.ackFailure(
          job.id,
          error is CupsException
              ? error.status.name.toUpperCase()
              : 'PRINT_FAILED',
          _safeMessage(error),
          duration,
        );
      } catch (ackError) {
        _log(
          'job ${job.id} print failed and failure ack failed: ${_safeMessage(ackError)}',
        );
        rethrow;
      }
      _log('job ${job.id} failed: ${_safeMessage(error)}');
      return;
    }

    final duration = DateTime.now().difference(started);
    // CUPS transport returns only after lpstat observes completed; ack is kept
    // after that boundary so lp accepting a file is never treated as success.
    await _api.ackSuccess(job.id, duration);
    _log('job ${job.id} printed in ${duration.inMilliseconds}ms');
  }

  PrinterProfile _selectProfile(GatewayJob job) {
    final available = printers.where((printer) => printer.enabled).toList();
    if (available.isEmpty) {
      throw StateError('Không có local printer profile enabled.');
    }
    final requestedId = _text(job.payload['target_printer_id']);
    if (requestedId.isNotEmpty) {
      final exact = available.where((printer) => printer.id == requestedId);
      if (exact.isNotEmpty) return exact.first;
    }
    final targetRole = switch (job.jobType) {
      'kitchen_ticket' => 'kitchen',
      'table_qr' => 'qr',
      'cash_drawer' => 'cash_drawer',
      _ => 'receipt',
    };
    final area = _text(job.payload['area_id']);
    final station = _text(job.payload['station_name']);
    final scored = available.map((printer) {
      var score = 0;
      if (printer.role.toLowerCase() == targetRole) score += 100;
      if (area.isNotEmpty && printer.area == area) score += 20;
      if (station.isNotEmpty && printer.station == station) score += 20;
      if (targetRole == 'cash_drawer' && printer.cashDrawer) score += 10;
      return (score: score, printer: printer);
    }).toList()..sort((a, b) => b.score.compareTo(a.score));
    if (scored.first.score == 0) {
      throw StateError(
        'Không có local printer profile phù hợp cho ${job.jobType}.',
      );
    }
    return scored.first.printer;
  }
}

String _text(Object? value) => value?.toString().trim() ?? '';

String _safeMessage(Object error) {
  if (error is GatewayApiException && error.message.contains('Bearer')) {
    return 'Gateway API error ${error.statusCode}';
  }
  return error.toString().replaceAll(
    RegExp(r'(token|password|secret)\s*[:=]\s*\S+', caseSensitive: false),
    r'$1=[redacted]',
  );
}
