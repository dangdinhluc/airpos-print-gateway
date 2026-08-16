import 'dart:async';
import 'dart:io';

import 'cups.dart';
import 'escpos.dart';
import 'gateway_api.dart';
import 'models.dart';
import 'print_profile.dart';

class GatewayPrinterService {
  GatewayPrinterService({
    CupsPrintTransport? cups,
    GatewayPrintRenderer? renderer,
  }) : _cups = cups ?? CupsPrintTransport(),
       _renderer = renderer ?? const GatewayPrintRenderer();

  final CupsPrintTransport _cups;
  final GatewayPrintRenderer _renderer;

  Future<void> printJob(
    GatewayJob job,
    PrinterProfile profile, {
    StorePrintProfile? printProfile,
  }) async {
    final effective = profile.copyWith(
      capabilities: await probeCapabilities(profile),
    );
    final document = await _renderer.renderJob(
      job,
      effective,
      printProfile: printProfile,
    );
    await _send(effective, document);
  }

  Future<void> test(
    PrinterProfile profile,
    TestPrintAction action, {
    StorePrintProfile? printProfile,
  }) async {
    final effective = profile.copyWith(
      capabilities: await probeCapabilities(profile),
    );
    final document = await _renderer.renderTest(
      effective,
      action: action,
      printProfile: printProfile,
    );
    await _send(effective, document);
  }

  String previewText({
    required String type,
    StorePrintProfile? printProfile,
    int paperWidthMm = 80,
  }) {
    return _renderer.renderSamplePreviewText(
      jobType: type == 'kitchen' ? 'kitchen_ticket' : 'receipt',
      printProfile: printProfile,
      paperWidthMm: paperWidthMm,
    );
  }

  String? get fontWarning => _renderer.fontWarning;

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
    final pages = document.printablePages.toList(growable: false);
    if (profile.usesCups) {
      for (final page in pages) {
        await _cups.print(
          profile,
          page.bytes,
          options: page.cupsOptions,
          raw: page.raw,
        );
      }
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
      for (final page in pages) {
        socket.add(page.bytes);
      }
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
    StorePrintProfile? printProfile,
    GatewayPrinterService? printerService,
    void Function(String message)? log,
  }) : _api = api,
       printProfile = printProfile ?? StorePrintProfile(),
       _printerService = printerService ?? GatewayPrinterService(),
       _log = log ?? print;

  final GatewayConfig config;
  final List<PrinterProfile> printers;
  final StorePrintProfile printProfile;
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
    final heartbeat = await _api.heartbeat(
      config.appVersion,
      metadata: buildGatewayHeartbeatMetadata(printers),
    );
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
      await _printerService.printJob(job, profile, printProfile: printProfile);
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

Map<String, Object?> buildGatewayHeartbeatMetadata(
  Iterable<PrinterProfile> printers,
) {
  final localPrinters = <Map<String, Object?>>[];
  final roles = <String>{};
  for (final printer in printers) {
    if (!printer.enabled) continue;
    final localRole = printer.role.trim().toLowerCase();
    if (localRole.isEmpty) continue;
    final publishedRole = localRole == 'receipt' ? 'pos' : localRole;
    roles.add(publishedRole);
    localPrinters.add(<String, Object?>{
      'id': printer.id,
      'name': printer.name,
      'role': publishedRole,
      'station_name': printer.station.isEmpty ? null : printer.station,
      'area_id': printer.area.isEmpty ? null : printer.area,
      'connection': printer.connectionType.value,
      'protocol': printer.protocol.value,
      'ip': printer.host,
      'port': printer.port,
      'paper_width': printer.paperWidthMm,
    });
  }
  return <String, Object?>{
    'platform': 'ubuntu',
    'printer_roles': roles.toList(growable: false),
    'local_printers': localPrinters,
  };
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
