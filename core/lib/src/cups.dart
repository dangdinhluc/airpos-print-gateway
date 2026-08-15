import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'models.dart';
import 'process_runner.dart';

class CupsDevice {
  const CupsDevice({
    required this.transport,
    required this.uri,
    required this.description,
  });

  final String transport;
  final String uri;
  final String description;
}

class CupsQueue {
  const CupsQueue({required this.name, required this.status});

  final String name;
  final String status;

  bool get isDisabled => status.toLowerCase().contains('disabled');
}

class CupsModel {
  const CupsModel({required this.name, required this.description});

  final String name;
  final String description;
}

class CupsSnapshot {
  const CupsSnapshot({
    required this.devices,
    required this.queues,
    required this.models,
    this.defaultQueue,
  });

  final List<CupsDevice> devices;
  final List<CupsQueue> queues;
  final List<CupsModel> models;
  final String? defaultQueue;
}

class CupsException implements Exception {
  const CupsException(this.status, this.message);

  final PrinterHealthStatus status;
  final String message;

  @override
  String toString() => message;
}

class CupsDiscoveryService {
  const CupsDiscoveryService({
    CommandRunner runner = const ProcessCommandRunner(),
  }) : _runner = runner;

  final CommandRunner _runner;

  Future<CupsSnapshot> discover() async {
    final devicesResult = await _runner.run('lpinfo', <String>['-v']);
    if (!devicesResult.isSuccess) {
      throw CupsException(
        _classifyError('${devicesResult.stdout}\n${devicesResult.stderr}'),
        'Không thể dò thiết bị CUPS: ${_cleanError(devicesResult.stderr)}',
      );
    }

    final queuesResult = await _runner.run('lpstat', <String>['-p', '-d']);
    if (!queuesResult.isSuccess) {
      throw CupsException(
        _classifyError('${queuesResult.stdout}\n${queuesResult.stderr}'),
        'Không thể dò hàng đợi CUPS: ${_cleanError(queuesResult.stderr)}',
      );
    }

    final modelsResult = await _runner.run('lpinfo', <String>['-m']);
    final models = modelsResult.isSuccess
        ? parseModels(modelsResult.stdout)
        : const <CupsModel>[];
    return CupsSnapshot(
      devices: parseDevices(devicesResult.stdout),
      queues: parseQueues(queuesResult.stdout),
      models: models,
      defaultQueue: parseDefaultQueue(queuesResult.stdout),
    );
  }

  static List<CupsDevice> parseDevices(String output) {
    final devices = <CupsDevice>[];
    for (final rawLine in output.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final uri = parts[1];
      if (!isSafeDeviceUri(uri)) continue;
      devices.add(
        CupsDevice(
          transport: parts.first,
          uri: uri,
          description: parts.sublist(2).join(' ').trim(),
        ),
      );
    }
    return devices;
  }

  static List<CupsQueue> parseQueues(String output) {
    final queues = <CupsQueue>[];
    for (final rawLine in output.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith('printer ')) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2 || !isSafeQueueName(parts[1])) continue;
      queues.add(CupsQueue(name: parts[1], status: line));
    }
    return queues;
  }

  static List<CupsModel> parseModels(String output) {
    final models = <CupsModel>[];
    for (final rawLine in output.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.isEmpty || parts.first.startsWith('-')) continue;
      models.add(
        CupsModel(
          name: parts.first,
          description: parts.sublist(1).join(' ').trim(),
        ),
      );
    }
    return models;
  }

  static String? parseDefaultQueue(String output) {
    final match = RegExp(
      r'^system default destination:\s*(\S+)',
      multiLine: true,
    ).firstMatch(output);
    final value = match?.group(1);
    return value != null && isSafeQueueName(value) ? value : null;
  }
}

class CupsPrinterStatusService {
  const CupsPrinterStatusService({
    CommandRunner runner = const ProcessCommandRunner(),
  }) : _runner = runner;

  final CommandRunner _runner;

  Future<PrinterHealth> inspect(PrinterProfile profile) async {
    final queue = profile.cupsQueue?.trim() ?? '';
    if (queue.isEmpty || !isSafeQueueName(queue)) {
      return const PrinterHealth(
        status: PrinterHealthStatus.queueMissing,
        detail: 'Chưa cấu hình CUPS queue.',
      );
    }

    final result = await _runner.run('lpstat', <String>['-p', queue]);
    if (!result.isSuccess) {
      return PrinterHealth(
        status: _classifyError('${result.stdout}\n${result.stderr}'),
        detail: _cleanError(result.stderr),
      );
    }

    final text = '${result.stdout}\n${result.stderr}'.toLowerCase();
    if (text.contains('disabled') ||
        text.contains('stopped') ||
        text.contains('error')) {
      return PrinterHealth(
        status: PrinterHealthStatus.printerError,
        detail: result.stdout.trim(),
      );
    }
    if (profile.protocol == PrinterProtocol.starCups) {
      final options = await _runner.run('lpoptions', <String>[
        '-p',
        queue,
        '-l',
      ]);
      if (!options.isSuccess) {
        final status = _classifyError('${options.stdout}\n${options.stderr}');
        if (status == PrinterHealthStatus.driverMissing ||
            status == PrinterHealthStatus.permissionDenied) {
          return PrinterHealth(
            status: status,
            detail: _cleanError(options.stderr),
          );
        }
      }
    }
    return const PrinterHealth(status: PrinterHealthStatus.connected);
  }

  Future<PrinterCapabilities> probeCapabilities(PrinterProfile profile) async {
    final base = profile.effectiveCapabilities;
    if (profile.protocol != PrinterProtocol.starCups) return base;
    final queue = profile.cupsQueue?.trim() ?? '';
    if (queue.isEmpty || !isSafeQueueName(queue)) return base;
    final result = await _runner.run('lpoptions', <String>['-p', queue, '-l']);
    if (!result.isSuccess) {
      return base.copyWith(
        cut: false,
        cashDrawer: false,
        beep: false,
        warning: 'Không đọc được Star CUPS driver của queue này.',
        replaceWarning: true,
      );
    }
    final text = '${result.stdout}\n${result.stderr}'.toLowerCase();
    final supportsCut = RegExp(r'cut|cutter|pagecut').hasMatch(text);
    final supportsDrawer = RegExp(r'cash.?drawer|drawer').hasMatch(text);
    final supportsBeep = RegExp(r'buzzer|beep').hasMatch(text);
    final missing = <String>[
      if (!supportsCut) 'cut',
      if (!supportsDrawer) 'cash drawer',
      if (!supportsBeep) 'beep',
    ];
    return base.copyWith(
      cut: supportsCut,
      cashDrawer: supportsDrawer,
      beep: supportsBeep,
      warning: missing.isEmpty
          ? null
          : 'Star CUPS driver không khai báo: ${missing.join(', ')}.',
      replaceWarning: true,
    );
  }
}

class CupsPrintTransport {
  CupsPrintTransport({
    CommandRunner runner = const ProcessCommandRunner(),
    Duration pollInterval = const Duration(milliseconds: 300),
  }) : _runner = runner,
       _pollInterval = pollInterval;

  final CommandRunner _runner;
  final Duration _pollInterval;

  Future<CupsPrintResult> print(
    PrinterProfile profile,
    List<int> bytes, {
    Map<String, String> options = const <String, String>{},
    Duration timeout = const Duration(seconds: 90),
    bool raw = false,
  }) async {
    final queue = profile.cupsQueue?.trim() ?? '';
    if (queue.isEmpty || !isSafeQueueName(queue)) {
      throw const CupsException(
        PrinterHealthStatus.queueMissing,
        'CUPS queue chưa được cấu hình ở local printer profile.',
      );
    }
    if (bytes.isEmpty) {
      throw const CupsException(
        PrinterHealthStatus.printerError,
        'Không thể gửi tài liệu rỗng tới CUPS.',
      );
    }

    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'airpos-print-gateway-',
    );
    final inputFile = File(
      '${temporaryDirectory.path}/job-${Random().nextInt(1 << 32)}${raw ? '.raw' : '.png'}',
    );
    try {
      await inputFile.writeAsBytes(bytes, flush: true);
      final arguments = <String>['-d', queue];
      if (raw) arguments.addAll(<String>['-o', 'raw']);
      for (final entry in options.entries) {
        if (!isSafeOption(entry.key) || !isSafeOption(entry.value)) {
          throw const CupsException(
            PrinterHealthStatus.printerError,
            'CUPS option không hợp lệ.',
          );
        }
        arguments.addAll(<String>['-o', '${entry.key}=${entry.value}']);
      }
      arguments.add(inputFile.path);
      final submit = await _runner.run('lp', arguments);
      if (!submit.isSuccess) {
        throw CupsException(
          _classifyError('${submit.stdout}\n${submit.stderr}'),
          'CUPS không nhận job: ${_cleanError(submit.stderr)}',
        );
      }
      final requestId = _requestId(submit.stdout, queue);
      if (requestId == null) {
        throw const CupsException(
          PrinterHealthStatus.printerError,
          'CUPS không trả request id; job chưa được xác nhận hoàn tất.',
        );
      }
      await _waitForCompletion(queue, requestId, timeout);
      return CupsPrintResult(requestId: requestId);
    } on CommandTimeoutException catch (error) {
      throw CupsException(PrinterHealthStatus.printerError, error.toString());
    } finally {
      try {
        await temporaryDirectory.delete(recursive: true);
      } catch (_) {
        // Temporary print files are best-effort cleanup after the job result.
      }
    }
  }

  Future<void> _waitForCompletion(
    String queue,
    String requestId,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final active = await _runner.run('lpstat', <String>[
        '-W',
        'not-completed',
        '-o',
        queue,
      ]);
      if (!active.isSuccess) {
        throw CupsException(
          _classifyError('${active.stdout}\n${active.stderr}'),
          'Không đọc được trạng thái CUPS: ${_cleanError(active.stderr)}',
        );
      }
      if (_containsJob(active.stdout, requestId)) {
        await Future<void>.delayed(_pollInterval);
        continue;
      }

      final completed = await _runner.run('lpstat', <String>[
        '-W',
        'completed',
        '-o',
        queue,
      ]);
      if (!completed.isSuccess) {
        throw CupsException(
          _classifyError('${completed.stdout}\n${completed.stderr}'),
          'Không đọc được job completed của CUPS: ${_cleanError(completed.stderr)}',
        );
      }
      if (_containsJob(completed.stdout, requestId)) return;

      final all = await _runner.run('lpstat', <String>[
        '-W',
        'all',
        '-o',
        queue,
      ]);
      if (!all.isSuccess) {
        throw CupsException(
          _classifyError('${all.stdout}\n${all.stderr}'),
          'Không đọc được lịch sử job CUPS: ${_cleanError(all.stderr)}',
        );
      }
      if (_containsJob(all.stdout, requestId)) {
        final text = all.stdout.toLowerCase();
        if (text.contains('aborted') ||
            text.contains('stopped') ||
            text.contains('error')) {
          throw const CupsException(
            PrinterHealthStatus.printerError,
            'CUPS báo job in lỗi.',
          );
        }
        return;
      }
      await Future<void>.delayed(_pollInterval);
    }
    throw CupsException(
      PrinterHealthStatus.printerError,
      'CUPS timeout sau ${timeout.inSeconds}s; worker không ack thành công.',
    );
  }

  static String? _requestId(String output, String queue) {
    final match = RegExp(
      r'request id is\s+([^\s]+)',
      caseSensitive: false,
    ).firstMatch(output);
    final candidate =
        match?.group(1)?.trim() ??
        RegExp(
          '${RegExp.escape(queue)}-[A-Za-z0-9_.-]+',
        ).firstMatch(output)?.group(0)?.trim();
    if (candidate == null || candidate.isEmpty) return null;
    return candidate.startsWith('$queue-') ? candidate : null;
  }

  static bool _containsJob(String output, String requestId) {
    return output.split(RegExp(r'\s+')).contains(requestId);
  }
}

class CupsSetupService {
  const CupsSetupService({
    required CupsDiscoveryService discovery,
    CommandRunner runner = const ProcessCommandRunner(),
  }) : _discovery = discovery,
       _runner = runner;

  final CupsDiscoveryService _discovery;
  final CommandRunner _runner;

  Future<void> createQueue({
    required String queue,
    required String deviceUri,
    required String model,
  }) async {
    if (!isSafeQueueName(queue)) {
      throw const CupsException(
        PrinterHealthStatus.queueMissing,
        'Tên CUPS queue chỉ được chứa chữ, số, dấu chấm, gạch ngang hoặc gạch dưới.',
      );
    }
    if (!isSafeDeviceUri(deviceUri)) {
      throw const CupsException(
        PrinterHealthStatus.printerError,
        'Device URI không hợp lệ hoặc không nằm trong danh sách lpinfo.',
      );
    }
    if (model.trim().isEmpty || model.contains(RegExp(r'[\r\n]'))) {
      throw const CupsException(
        PrinterHealthStatus.driverMissing,
        'CUPS driver/model chưa được chọn.',
      );
    }

    final snapshot = await _discovery.discover();
    if (!snapshot.devices.any((device) => device.uri == deviceUri)) {
      throw const CupsException(
        PrinterHealthStatus.printerError,
        'Device URI không còn xuất hiện trong lpinfo; hãy quét lại USB.',
      );
    }
    if (model != 'raw' && !snapshot.models.any((item) => item.name == model)) {
      throw const CupsException(
        PrinterHealthStatus.driverMissing,
        'Driver/model không có trong lpinfo -m.',
      );
    }

    final result = await _runner.run('lpadmin', <String>[
      '-p',
      queue,
      '-v',
      deviceUri,
      '-m',
      model,
      '-E',
    ]);
    if (!result.isSuccess) {
      throw CupsException(
        _classifyError('${result.stdout}\n${result.stderr}'),
        'Không tạo được CUPS queue: ${_cleanError(result.stderr)}',
      );
    }
  }
}

bool isSafeQueueName(String value) {
  return value.length <= 127 && RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value);
}

bool isSafeDeviceUri(String value) {
  final uri = value.trim();
  if (uri.isEmpty || uri.length > 1024 || uri.contains(RegExp(r'[\r\n\s]'))) {
    return false;
  }
  if (uri.startsWith('/dev/')) return false;
  return RegExp(
    r'^(usb|bluetooth|socket|ipp|ipps|dnssd|lpd|http|https):',
    caseSensitive: false,
  ).hasMatch(uri);
}

bool isSafeOption(String value) {
  return value.isNotEmpty &&
      value.length <= 127 &&
      !value.contains(RegExp(r'[\r\n]')) &&
      !value.startsWith('-');
}

PrinterHealthStatus _classifyError(String text) {
  final value = text.toLowerCase();
  if (value.contains('permission denied') ||
      value.contains('not authorized') ||
      value.contains('unauthorized')) {
    return PrinterHealthStatus.permissionDenied;
  }
  if (value.contains('driver') ||
      value.contains('filter failed') ||
      value.contains('ppd')) {
    return PrinterHealthStatus.driverMissing;
  }
  if (value.contains('unknown printer') ||
      value.contains('unknown destination') ||
      value.contains('does not exist') ||
      value.contains('not found')) {
    return PrinterHealthStatus.queueMissing;
  }
  if (value.contains('stopped') ||
      value.contains('unplug') ||
      value.contains('backend') ||
      value.contains('printer error')) {
    return PrinterHealthStatus.printerError;
  }
  return PrinterHealthStatus.unavailable;
}

String _cleanError(String error) {
  final value = error.trim().replaceAll(RegExp(r'\s+'), ' ');
  return value.isEmpty ? 'CUPS command failed.' : value;
}
