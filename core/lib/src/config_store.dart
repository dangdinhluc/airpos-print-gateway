import 'dart:convert';
import 'dart:io';

import 'models.dart';

class GatewayConfigStore {
  GatewayConfigStore({String? homeDirectory, String? configDirectory})
    : _shared = _resolveConfigDirectory(configDirectory) != null,
      rootDirectory = Directory(
        _resolveConfigDirectory(configDirectory) ??
            '${homeDirectory ?? Platform.environment['HOME'] ?? '.'}/.config/airpos/print-gateway',
      );

  final bool _shared;
  final Directory rootDirectory;

  File get configFile => File('${rootDirectory.path}/config.json');

  File get printersFile => File('${rootDirectory.path}/printers.json');

  Future<GatewayConfig?> loadConfig() async {
    final json = await _readObject(configFile);
    if (json == null) return null;
    final config = GatewayConfig.fromJson(json);
    // Remove legacy Supabase URL/anon-key fields the first time the browser
    // gateway reads a config written by the old desktop UI.
    if (json.containsKey('base_url') || json.containsKey('anon_key')) {
      await saveConfig(config);
    }
    return config;
  }

  Future<void> saveConfig(GatewayConfig config) async {
    await _writeObject(configFile, config.toJson());
  }

  Future<List<PrinterProfile>> loadPrinters() async {
    final fileJson = await _readObject(printersFile);
    final raw = fileJson?['printers'];
    if (raw is! List) return <PrinterProfile>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((json) => PrinterProfile.fromJson(Map<String, dynamic>.from(json)))
        .toList(growable: false);
  }

  Future<void> savePrinters(Iterable<PrinterProfile> printers) async {
    await _writeObject(printersFile, <String, Object?>{
      'printers': printers.map((printer) => printer.toJson()).toList(),
    });
  }

  Future<void> _writeObject(File file, Map<String, Object?> value) async {
    await rootDirectory.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file.path);
    // Gateway token is a local credential. chmod is best-effort on non-Unix
    // development hosts and remains enforced by the Ubuntu package installer.
    await Process.run('chmod', <String>[
      _shared ? '660' : '600',
      file.path,
    ], runInShell: false);
  }

  Future<Map<String, dynamic>?> _readObject(File file) async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }
}

String? _resolveConfigDirectory(String? explicit) {
  final value =
      (explicit ??
              Platform.environment['AIRPOS_PRINT_GATEWAY_CONFIG_DIR'] ??
              '')
          .trim();
  return value.isEmpty ? null : value;
}
