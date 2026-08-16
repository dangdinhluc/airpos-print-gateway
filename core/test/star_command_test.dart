import 'package:airpos_print_gateway_core/src/models.dart';
import 'package:airpos_print_gateway_core/src/star_command.dart';
import 'package:test/test.dart';

void main() {
  test(
    'mC-Print3 uses official StarPRNT conversion without scaling or dither',
    () {
      const profile = PrinterProfile(
        id: 'star-80',
        name: 'Star mC-Print3',
        connectionType: ConnectionType.usb,
        protocol: PrinterProtocol.starCups,
        paperWidthMm: 80,
        cut: true,
      );

      expect(
        StarCommandEncoder.arguments(
          profile,
          '/tmp/input.png',
          '/tmp/output.starprnt',
        ),
        <String>[
          'thermal80',
          'partialcut',
          'decode',
          'application/vnd.star.starprnt',
          '/tmp/input.png',
          '/tmp/output.starprnt',
        ],
      );
    },
  );
}
