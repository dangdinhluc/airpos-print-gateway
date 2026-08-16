import 'dart:io';

import 'cups.dart';
import 'models.dart';

const String defaultStarCputilPath = '/opt/airpos-print-gateway/bin/cputil';

class StarCommandEncoder {
  const StarCommandEncoder({this.executable = defaultStarCputilPath});

  final String executable;

  static List<String> arguments(
    PrinterProfile profile,
    String inputPath,
    String outputPath,
  ) => <String>[
    profile.paperWidthMm == 58 ? 'thermal58' : 'thermal80',
    if (profile.cut) 'partialcut',
    if (profile.cashDrawer) 'drawer-end',
    'decode',
    'application/vnd.star.starprnt',
    inputPath,
    outputPath,
  ];

  Future<List<int>> encode(PrinterProfile profile, List<int> png) async {
    final directory = await Directory.systemTemp.createTemp('airpos-star-');
    final input = File('${directory.path}/receipt.png');
    final output = File('${directory.path}/receipt.starprnt');
    try {
      await input.writeAsBytes(png, flush: true);
      final result = await Process.run(
        executable,
        arguments(profile, input.path, output.path),
        runInShell: false,
      );
      if (result.exitCode != 0 || !await output.exists()) {
        throw CupsException(
          PrinterHealthStatus.driverMissing,
          'StarPRNT converter failed: ${result.stderr}'.trim(),
        );
      }
      return await output.readAsBytes();
    } on ProcessException catch (_) {
      throw const CupsException(
        PrinterHealthStatus.driverMissing,
        'StarPRNT converter is not installed.',
      );
    } finally {
      await directory.delete(recursive: true);
    }
  }
}
