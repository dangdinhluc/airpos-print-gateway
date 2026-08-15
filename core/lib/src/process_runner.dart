import 'dart:async';
import 'dart:io';

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get isSuccess => exitCode == 0;
}

abstract interface class CommandRunner {
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout,
  });
}

class CommandTimeoutException implements Exception {
  const CommandTimeoutException(this.executable, this.timeout);

  final String executable;
  final Duration timeout;

  @override
  String toString() => '$executable timed out after ${timeout.inSeconds}s';
}

class ProcessCommandRunner implements CommandRunner {
  const ProcessCommandRunner();

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final future = Process.run(
      executable,
      arguments,
      runInShell: false,
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );
    try {
      final result = await future.timeout(
        timeout,
        onTimeout: () => throw CommandTimeoutException(executable, timeout),
      );
      return CommandResult(
        exitCode: result.exitCode,
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
      );
    } on ProcessException catch (error) {
      return CommandResult(exitCode: 127, stdout: '', stderr: error.message);
    }
  }
}
