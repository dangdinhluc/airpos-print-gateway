import 'dart:async';
import 'dart:io';

import 'package:airpos_print_gateway_core/airpos_print_gateway_core.dart';

Future<void> main() async {
  final settings = GatewayRuntimeSettings.fromEnvironment();
  final webRoot = Platform.environment['AIRPOS_GATEWAY_WEB_ROOT']?.trim();
  final runtime = GatewayRuntime(
    settings: settings,
    store: GatewayConfigStore(),
    webRoot: Directory(
      webRoot == null || webRoot.isEmpty
          ? const String.fromEnvironment(
              'AIRPOS_GATEWAY_WEB_ROOT',
              defaultValue: '/opt/airpos-print-gateway/web',
            )
          : webRoot,
    ),
    log: (message) => stdout.writeln('[airpos-print-gateway] $message'),
  );
  final stopped = Completer<void>();

  Future<void> shutdown() async {
    if (stopped.isCompleted) return;
    await runtime.stop();
    stopped.complete();
  }

  ProcessSignal.sigterm.watch().listen((_) => unawaited(shutdown()));
  ProcessSignal.sigint.watch().listen((_) => unawaited(shutdown()));

  await runtime.start();
  await stopped.future;
}
