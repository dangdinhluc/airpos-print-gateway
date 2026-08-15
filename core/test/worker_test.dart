import 'package:airpos_print_gateway_core/airpos_print_gateway_core.dart';
import 'package:test/test.dart';

void main() {
  test('publishes enabled Linux printer profiles for the POS picker', () {
    final metadata = buildGatewayHeartbeatMetadata(<PrinterProfile>[
      const PrinterProfile(
        id: 'receipt-usb',
        name: 'Receipt USB',
        connectionType: ConnectionType.usb,
        protocol: PrinterProtocol.escpos,
        cupsQueue: 'receipt',
        cupsDeviceUri: 'usb://EPSON/TM-T20III',
        role: 'receipt',
        area: 'front',
        station: 'cashier',
      ),
      const PrinterProfile(
        id: 'kitchen-usb',
        name: 'Kitchen USB',
        connectionType: ConnectionType.usb,
        protocol: PrinterProtocol.escpos,
        cupsQueue: 'kitchen',
        cupsDeviceUri: 'usb://EPSON/TM-T20III-2',
        role: 'kitchen',
        enabled: true,
      ),
      const PrinterProfile(
        id: 'disabled',
        name: 'Disabled',
        connectionType: ConnectionType.usb,
        protocol: PrinterProtocol.escpos,
        role: 'receipt',
        enabled: false,
      ),
    ]);

    final localPrinters =
        (metadata['local_printers']! as List).cast<Map<String, Object?>>();
    expect(metadata['platform'], 'ubuntu');
    expect(metadata['printer_roles'], <String>['pos', 'kitchen']);
    expect(localPrinters, hasLength(2));
    expect(
      localPrinters.first,
      allOf(
        containsPair('id', 'receipt-usb'),
        containsPair('role', 'pos'),
        containsPair('station_name', 'cashier'),
        containsPair('area_id', 'front'),
        containsPair('connection', 'usb'),
        containsPair('protocol', 'escpos'),
      ),
    );
    expect(localPrinters.map((item) => item['id']), isNot(contains('disabled')));
  });
}
