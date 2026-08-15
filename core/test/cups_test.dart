import 'package:airpos_print_gateway_core/airpos_print_gateway_core.dart';
import 'package:test/test.dart';

void main() {
  group('CUPS parsing and validation', () {
    test('maps lpinfo and lpstat output without trusting /dev paths', () {
      final devices = CupsDiscoveryService.parseDevices('''
Device: usb://EPSON/TM-T20III?serial=ABC EPSON TM-T20III
direct socket://192.168.1.20:9100 Network printer
direct /dev/usb/lp0 Raw device
''');
      final queues = CupsDiscoveryService.parseQueues('''
printer receipt is idle.  enabled since Sat 15 Aug 2026
printer kitchen is disabled since Sat 15 Aug 2026
system default destination: receipt
''');

      expect(
        devices.map((item) => item.uri),
        contains('usb://EPSON/TM-T20III?serial=ABC'),
      );
      expect(
        devices.map((item) => item.uri),
        contains('socket://192.168.1.20:9100'),
      );
      expect(devices.map((item) => item.uri), isNot(contains('/dev/usb/lp0')));
      expect(
        queues.map((item) => item.name),
        containsAll(<String>['receipt', 'kitchen']),
      );
      expect(queues.last.isDisabled, isTrue);
      expect(
        CupsDiscoveryService.parseDefaultQueue(
          'system default destination: receipt',
        ),
        'receipt',
      );
      expect(isSafeQueueName('receipt_80mm'), isTrue);
      expect(isSafeQueueName('receipt;rm'), isFalse);
      expect(isSafeDeviceUri('/dev/usb/lp0'), isFalse);
    });

    test('star capabilities disable unsupported beep', () {
      final capabilities = defaultCapabilities(
        ConnectionType.usb,
        PrinterProtocol.starCups,
      );
      expect(capabilities.cut, isTrue);
      expect(capabilities.cashDrawer, isTrue);
      expect(capabilities.beep, isFalse);
      expect(capabilities.warning, contains('disabled'));
    });

    test('Star driver probe disables actions when lpoptions fails', () async {
      final runner = FakeRunner(<String, List<CommandResult>>{
        'lpoptions|-p star_receipt -l': <CommandResult>[
          const CommandResult(
            exitCode: 1,
            stdout: '',
            stderr: 'Unable to get PPD: driver missing',
          ),
        ],
      });
      final capabilities = await CupsPrinterStatusService(
        runner: runner,
      ).probeCapabilities(
        const PrinterProfile(
          id: 'star',
          name: 'Star',
          connectionType: ConnectionType.usb,
          protocol: PrinterProtocol.starCups,
          cupsQueue: 'star_receipt',
          cupsDeviceUri: 'usb://Star/mC-Print3',
        ),
      );

      expect(capabilities.cut, isFalse);
      expect(capabilities.cashDrawer, isFalse);
      expect(capabilities.beep, isFalse);
      expect(capabilities.warning, contains('driver'));
    });
  });

  group('CupsPrintTransport', () {
    test('waits for completed request before returning', () async {
      final runner = FakeRunner(<String, List<CommandResult>>{
        'lp|': <CommandResult>[
          const CommandResult(
            exitCode: 0,
            stdout: 'request id is receipt-42 (1 file(s))',
            stderr: '',
          ),
        ],
        'lpstat|-W not-completed -o receipt': <CommandResult>[
          const CommandResult(
            exitCode: 0,
            stdout: 'receipt-42 user 1024',
            stderr: '',
          ),
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
        ],
        'lpstat|-W completed -o receipt': <CommandResult>[
          const CommandResult(
            exitCode: 0,
            stdout: 'receipt-42 user 1024',
            stderr: '',
          ),
        ],
      });
      final profile = _usbProfile();

      final result =
          await CupsPrintTransport(
            runner: runner,
            pollInterval: Duration.zero,
          ).print(
            profile,
            <int>[1, 2, 3],
            raw: true,
            timeout: const Duration(seconds: 1),
          );

      expect(result.requestId, 'receipt-42');
      expect(runner.calls.map((call) => call.executable), <String>[
        'lp',
        'lpstat',
        'lpstat',
        'lpstat',
      ]);
      expect(
        runner.calls.first.arguments,
        containsAll(<String>['-d', 'receipt', '-o', 'raw']),
      );
    });

    test('does not acknowledge a submit without a request id', () async {
      final runner = FakeRunner(<String, List<CommandResult>>{
        'lp|': <CommandResult>[
          const CommandResult(exitCode: 0, stdout: 'job accepted', stderr: ''),
        ],
      });
      await expectLater(
        CupsPrintTransport(
          runner: runner,
        ).print(_usbProfile(), <int>[1], raw: true),
        throwsA(
          isA<CupsException>().having(
            (error) => error.message,
            'message',
            contains('request id'),
          ),
        ),
      );
      expect(runner.calls.length, 1);
    });

    test('maps queue errors to queue missing and permission errors', () async {
      final missing = FakeRunner(<String, List<CommandResult>>{
        'lp|': <CommandResult>[
          const CommandResult(
            exitCode: 1,
            stdout: '',
            stderr: 'Unknown printer receipt',
          ),
        ],
      });
      expect(
        () => CupsPrintTransport(
          runner: missing,
        ).print(_usbProfile(), <int>[1], raw: true),
        throwsA(
          isA<CupsException>().having(
            (error) => error.status,
            'status',
            PrinterHealthStatus.queueMissing,
          ),
        ),
      );

      final denied = FakeRunner(<String, List<CommandResult>>{
        'lp|': <CommandResult>[
          const CommandResult(
            exitCode: 1,
            stdout: '',
            stderr: 'Permission denied',
          ),
        ],
      });
      expect(
        () => CupsPrintTransport(
          runner: denied,
        ).print(_usbProfile(), <int>[1], raw: true),
        throwsA(
          isA<CupsException>().having(
            (error) => error.status,
            'status',
            PrinterHealthStatus.permissionDenied,
          ),
        ),
      );
    });

    test('reports unplugged backend and timeout instead of success', () async {
      final unplugged = FakeRunner(<String, List<CommandResult>>{
        'lp|': <CommandResult>[
          const CommandResult(
            exitCode: 0,
            stdout: 'request id is receipt-44 (1 file(s))',
            stderr: '',
          ),
        ],
        'lpstat|-W not-completed -o receipt': <CommandResult>[
          const CommandResult(
            exitCode: 1,
            stdout: '',
            stderr: 'Backend failed: device unplugged',
          ),
        ],
      });
      await expectLater(
        CupsPrintTransport(
          runner: unplugged,
        ).print(_usbProfile(), <int>[1], raw: true),
        throwsA(
          isA<CupsException>().having(
            (error) => error.status,
            'status',
            PrinterHealthStatus.printerError,
          ),
        ),
      );

      final timeout = FakeRunner(<String, List<CommandResult>>{
        'lp|': <CommandResult>[
          const CommandResult(
            exitCode: 0,
            stdout: 'request id is receipt-45 (1 file(s))',
            stderr: '',
          ),
        ],
        'lpstat|-W not-completed -o receipt': <CommandResult>[
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
        ],
        'lpstat|-W completed -o receipt': <CommandResult>[
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
        ],
        'lpstat|-W all -o receipt': <CommandResult>[
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
        ],
      });
      await expectLater(
        CupsPrintTransport(
          runner: timeout,
          pollInterval: const Duration(milliseconds: 1),
        ).print(
          _usbProfile(),
          <int>[1],
          raw: true,
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(
          isA<CupsException>().having(
            (error) => error.message,
            'message',
            contains('timeout'),
          ),
        ),
      );
    });
  });

  test(
    'setup validates local URI and invokes lpadmin as the service user',
    () async {
      final runner = FakeRunner(<String, List<CommandResult>>{
        'lpinfo|-v': <CommandResult>[
          const CommandResult(
            exitCode: 0,
            stdout: 'direct usb://Star/mC-Print3',
            stderr: '',
          ),
        ],
        'lpstat|-p -d': <CommandResult>[
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
        ],
        'lpinfo|-m': <CommandResult>[
          const CommandResult(
            exitCode: 0,
            stdout: 'star-mc-print3.ppd Star mC-Print3',
            stderr: '',
          ),
        ],
        'lpadmin|': <CommandResult>[
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
        ],
      });
      await CupsSetupService(
        discovery: CupsDiscoveryService(runner: runner),
        runner: runner,
      ).createQueue(
        queue: 'star_receipt',
        deviceUri: 'usb://Star/mC-Print3',
        model: 'star-mc-print3.ppd',
      );

      final setupCall = runner.calls.last;
      expect(setupCall.executable, 'lpadmin');
      expect(setupCall.arguments, <String>[
        '-p',
        'star_receipt',
        '-v',
        'usb://Star/mC-Print3',
        '-m',
        'star-mc-print3.ppd',
        '-E',
      ]);
    },
  );

  test('ESC/POS renderer emits raster and QR bytes', () async {
    final document = await const GatewayPrintRenderer().renderJob(
      const GatewayJob(
        id: 'qr-1',
        jobType: 'table_qr',
        payload: <String, dynamic>{
          'qr_url': 'https://menu.example.test/tables/1',
          'table_label': 'Table 1',
        },
      ),
      _usbProfile(),
    );
    expect(document.raw, isTrue);
    expect(document.bytes, containsAllInOrder(<int>[0x1B, 0x40, 0x1B, 0x61]));
    expect(document.bytes.length, greaterThan(1000));
  });
}

PrinterProfile _usbProfile() => const PrinterProfile(
  id: 'receipt-usb',
  name: 'Receipt USB',
  connectionType: ConnectionType.usb,
  protocol: PrinterProtocol.escpos,
  cupsQueue: 'receipt',
  cupsDeviceUri: 'usb://EPSON/TM-T20III',
  printerModel: 'raw',
);

class FakeRunner implements CommandRunner {
  FakeRunner(this._scripts);

  final Map<String, List<CommandResult>> _scripts;
  final List<FakeCall> calls = <FakeCall>[];

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final call = FakeCall(executable, List<String>.from(arguments));
    calls.add(call);
    final key = '${call.executable}|${call.arguments.join(' ')}';
    final emptyKey = '${call.executable}|';
    final script = _scripts[key] ?? _scripts[emptyKey];
    if (script == null || script.isEmpty) {
      throw StateError('No fake CUPS response for $key');
    }
    return script.length == 1 ? script.first : script.removeAt(0);
  }
}

class FakeCall {
  const FakeCall(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}
