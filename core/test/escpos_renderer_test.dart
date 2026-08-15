import 'dart:io';

import 'package:airpos_print_gateway_core/src/escpos.dart';
import 'package:airpos_print_gateway_core/src/models.dart';
import 'package:airpos_print_gateway_core/src/print_profile.dart';
import 'package:test/test.dart';

void main() {
  const renderer = GatewayPrintRenderer(unicodeFontArchivePath: '');

  group('receipt preview presets', () {
    test('modern preset uses store header and standard receipt title', () {
      final text = renderer.renderPreviewText(
        payload: _receiptPayload(),
        printProfile: _profile(
          receiptTemplate: 'modern',
          headerTextVi: 'Xin chao',
          footerTextJa: 'Arigato',
        ),
      );

      expect(text, contains('Payload Store'));
      expect(text, contains('RECEIPT'));
      expect(text, isNot(contains('DETAILED RECEIPT')));
      expect(text, contains('Xin chao'));
      expect(text, contains('Arigato'));
    });

    test('classic preset renders classic title', () {
      final text = renderer.renderPreviewText(
        payload: _receiptPayload(),
        printProfile: _profile(receiptTemplate: 'classic'),
      );

      expect(text, contains('*** RECEIPT ***'));
      expect(text, contains('Payload Store'));
      expect(text, isNot(contains('DETAILED RECEIPT')));
    });

    test(
      'compact preset keeps compact header and suppresses metadata block',
      () {
        final text = renderer.renderPreviewText(
          payload: _receiptPayload(),
          printProfile: _profile(receiptTemplate: 'compact'),
        );

        expect(text, contains('RECEIPT #A-100'));
        expect(text, isNot(contains('Order: #A-100')));
        expect(text, isNot(contains('Cashier: Mai')));
        expect(text, contains('----------------'));
      },
    );

    test('detailed preset includes notes and payments', () {
      final text = renderer.renderPreviewText(
        payload: _receiptPayload(),
        printProfile: _profile(receiptTemplate: 'detailed'),
      );

      expect(text, contains('DETAILED RECEIPT'));
      expect(text, contains('No onion'));
      expect(text, contains('Payments:'));
      expect(text, contains('cash: JPY 1200'));
    });
  });

  group('kitchen preview presets', () {
    test('standard preset renders kitchen ticket title', () {
      final text = renderer.renderPreviewText(
        jobType: 'kitchen_ticket',
        payload: _kitchenPayload(),
        printProfile: _profile(kitchenTemplate: 'standard'),
      );

      expect(text, contains('KITCHEN TICKET'));
      expect(text, contains('Order: #A-100'));
      expect(text, contains('No onion'));
    });

    test('compact preset trims note lines', () {
      final text = renderer.renderPreviewText(
        jobType: 'kitchen_ticket',
        payload: _kitchenPayload(),
        printProfile: _profile(kitchenTemplate: 'compact'),
      );

      expect(text, contains('KITCHEN #A-100'));
      expect(text, isNot(contains('Order: #A-100')));
      expect(text, isNot(contains('No onion')));
      expect(text, contains('----------------'));
    });

    test('checklist preset uses checklist markers and cancellation title', () {
      final text = renderer.renderPreviewText(
        jobType: 'kitchen_ticket',
        payload: _kitchenPayload(isCancellation: true),
        printProfile: _profile(kitchenTemplate: 'checklist'),
      );

      expect(text, contains('CANCEL CHECKLIST'));
      expect(text, contains('[ ] 2 x Pho'));
      expect(text, contains('CANCEL: Customer changed mind'));
    });
  });

  test(
    'profile toggles and blank local fields fall back to payload store settings',
    () {
      final text = renderer.renderPreviewText(
        payload: _receiptPayload(timeSeatedMinutes: 42),
        printProfile: StorePrintProfile(
          storeName: '',
          storeNameJa: '',
          address: '',
          phone: '',
          taxId: '',
          headerTextVi: 'Header VI',
          footerTextJa: 'Footer JA',
          templateSettings: TemplateSettings(
            showOrderNumber: false,
            showTable: false,
            showDateTime: false,
            showStaffName: false,
            showQrCode: true,
            showTimeSeated: true,
          ),
        ),
      );

      expect(text, contains('Payload Store'));
      expect(text, contains('ペイロード店'));
      expect(text, contains('1-2-3 Shibuya'));
      expect(text, contains('03-1111-2222'));
      expect(text, contains('Header VI'));
      expect(text, contains('Footer JA'));
      expect(text, contains('Seated: 42 min'));
      expect(text, contains('QR: https://example.test/review'));
      expect(text, isNot(contains('Order: #A-100')));
      expect(text, isNot(contains('Table: B2')));
      expect(text, isNot(contains('Date: 2026-08-15 12:00')));
      expect(text, isNot(contains('Cashier: Mai')));
    },
  );

  test('nested receipt snapshot supplies order items totals and qr data', () {
    final text = renderer.renderPreviewText(
      payload: <String, dynamic>{
        'receipt_snapshot': <String, dynamic>{
          'store_settings': <String, dynamic>{
            'store_name': 'Snapshot Store',
            'currency': 'USD',
          },
          'qr_url': 'https://example.test/nested',
          'order': <String, dynamic>{
            'order_no': 'N-77',
            'created_at': '2026-08-15 13:00',
            'table': <String, dynamic>{'label': 'C9'},
            'staff_name': 'Nested Staff',
            'items': <Map<String, Object?>>[
              <String, Object?>{
                'quantity': 3,
                'name': 'Tea',
                'line_total': 9,
                'note': 'Less ice',
              },
            ],
            'total': 9,
          },
        },
      },
      printProfile: _profile(receiptTemplate: 'detailed', showQrCode: true),
    );

    expect(text, contains('Snapshot Store'));
    expect(text, contains('Order: #N-77'));
    expect(text, contains('Table: C9'));
    expect(text, contains('Cashier: Nested Staff'));
    expect(text, contains('3 x Tea  USD 9'));
    expect(text, contains('Less ice'));
    expect(text, contains('TOTAL: USD 9'));
    expect(text, contains('QR: https://example.test/nested'));
  });

  test('render sample preview text is deterministic without payload', () {
    expect(
      renderer.renderSamplePreviewText(jobType: 'receipt'),
      renderer.renderPreviewText(jobType: 'receipt'),
    );
    expect(
      renderer.renderSamplePreviewText(jobType: 'kitchen_ticket'),
      renderer.renderPreviewText(jobType: 'kitchen_ticket'),
    );
  });

  group('unicode font fallback', () {
    test('empty archive path keeps ASCII fallback warning', () async {
      const fallbackRenderer = GatewayPrintRenderer(unicodeFontArchivePath: '');

      final rendered = await fallbackRenderer.renderTest(_usbProfile());

      expect(rendered.raw, isTrue);
      expect(fallbackRenderer.packagedUnicodeFontAvailable, isFalse);
      expect(
        fallbackRenderer.fontWarning,
        'Unicode font archive path is empty; using ASCII raster font.',
      );
    });

    test('missing archive file keeps ASCII fallback warning', () async {
      final missingPath =
          '${Directory.systemTemp.path}/airpos-missing-${DateTime.now().microsecondsSinceEpoch}.fnt.zip';
      final fallbackRenderer = GatewayPrintRenderer(
        unicodeFontArchivePath: missingPath,
      );

      final rendered = await fallbackRenderer.renderTest(_usbProfile());

      expect(rendered.raw, isTrue);
      expect(fallbackRenderer.packagedUnicodeFontAvailable, isFalse);
      expect(
        fallbackRenderer.fontWarning,
        'Unicode font archive is not installed; using ASCII raster font.',
      );
    });

    test('invalid archive file keeps ASCII fallback warning', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'airpos-invalid-font-',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final invalidArchive = File('${tempDir.path}/invalid.fnt.zip');
      await invalidArchive.writeAsString('not-a-zip');
      final fallbackRenderer = GatewayPrintRenderer(
        unicodeFontArchivePath: invalidArchive.path,
      );

      final rendered = await fallbackRenderer.renderTest(_usbProfile());

      expect(rendered.raw, isTrue);
      expect(fallbackRenderer.packagedUnicodeFontAvailable, isFalse);
      expect(
        fallbackRenderer.fontWarning,
        startsWith('Unicode font archive failed to load:'),
      );
    });
  });

  test('receipt and kitchen test prints reuse preview templates', () async {
    final profile = _usbProfile();
    final printProfile = _profile(
      receiptTemplate: 'detailed',
      kitchenTemplate: 'checklist',
      showQrCode: true,
    );

    final receiptTest = await renderer.renderTest(
      profile,
      action: TestPrintAction.receipt,
      printProfile: printProfile,
    );
    final receiptJob = await renderer.renderJob(
      GatewayJob(
        id: 'receipt-test',
        jobType: 'receipt',
        payload: renderer.samplePayload(jobType: 'receipt'),
      ),
      profile,
      printProfile: printProfile,
    );
    final kitchenTest = await renderer.renderTest(
      profile,
      action: TestPrintAction.kitchen,
      printProfile: printProfile,
    );
    final kitchenJob = await renderer.renderJob(
      GatewayJob(
        id: 'kitchen-test',
        jobType: 'kitchen_ticket',
        payload: renderer.samplePayload(jobType: 'kitchen_ticket'),
      ),
      profile,
      printProfile: printProfile,
    );

    expect(receiptTest.raw, receiptJob.raw);
    expect(receiptTest.bytes, receiptJob.bytes);
    expect(kitchenTest.raw, kitchenJob.raw);
    expect(kitchenTest.bytes, kitchenJob.bytes);
  });

  test(
    'receipt render keeps qr raster plus cut and cash drawer commands',
    () async {
      final withQr = await renderer.renderJob(
        const GatewayJob(
          id: 'receipt-qr',
          jobType: 'receipt',
          payload: <String, dynamic>{
            'order_number': 'A-100',
            'table_label': 'B2',
            'created_at': '2026-08-15 12:00',
            'staff_name': 'Mai',
            'store_settings': <String, Object?>{
              'store_name': 'Payload Store',
              'currency': 'JPY',
            },
            'items': <Map<String, Object?>>[
              <String, Object?>{
                'quantity': 1,
                'name': 'Pho',
                'line_total': 1200,
              },
            ],
            'total': 1200,
            'qr_url': 'https://example.test/review',
          },
        ),
        _usbProfile(),
        printProfile: _profile(showQrCode: true),
      );
      final withoutQr = await renderer.renderJob(
        const GatewayJob(
          id: 'receipt-no-qr',
          jobType: 'receipt',
          payload: <String, dynamic>{
            'order_number': 'A-100',
            'items': <Map<String, Object?>>[
              <String, Object?>{
                'quantity': 1,
                'name': 'Pho',
                'line_total': 1200,
              },
            ],
            'total': 1200,
            'qr_url': 'https://example.test/review',
          },
        ),
        _usbProfile(),
        printProfile: _profile(showQrCode: false),
      );
      final cashDrawer = await renderer.renderJob(
        const GatewayJob(
          id: 'drawer-1',
          jobType: 'cash_drawer',
          payload: <String, dynamic>{},
        ),
        _usbProfile(),
      );

      expect(withQr.raw, isTrue);
      expect(withQr.bytes, containsAllInOrder(<int>[0x1B, 0x40, 0x1B, 0x61]));
      expect(
        withQr.bytes,
        containsAllInOrder(<int>[0x1B, 0x70, 0x00, 0x32, 0x32]),
      );
      expect(withQr.bytes, containsAllInOrder(<int>[0x1D, 0x56, 0x42, 0x00]));
      expect(withQr.bytes.length, greaterThan(withoutQr.bytes.length));

      expect(cashDrawer.raw, isTrue);
      expect(
        cashDrawer.bytes,
        containsAllInOrder(<int>[0x1B, 0x70, 0x00, 0x32, 0x32]),
      );
    },
  );
}

Map<String, dynamic> _receiptPayload({int timeSeatedMinutes = 0}) {
  return <String, dynamic>{
    'order_number': 'A-100',
    'table_label': 'B2',
    'created_at': '2026-08-15 12:00',
    'staff_name': 'Mai',
    'time_seated_minutes': timeSeatedMinutes == 0 ? null : timeSeatedMinutes,
    'store_settings': <String, Object?>{
      'store_name': 'Payload Store',
      'store_name_ja': 'ペイロード店',
      'address': '1-2-3 Shibuya',
      'phone': '03-1111-2222',
      'tax_id': 'TAX-99',
      'currency': 'JPY',
    },
    'items': <Map<String, Object?>>[
      <String, Object?>{
        'quantity': 2,
        'name': 'Pho',
        'line_total': 1200,
        'note': 'No onion',
      },
    ],
    'subtotal': 1200,
    'discount': 0,
    'tax': 0,
    'total': 1200,
    'payments': <Map<String, Object?>>[
      <String, Object?>{'method': 'cash', 'amount': 1200},
    ],
    'qr_url': 'https://example.test/review',
  };
}

Map<String, dynamic> _kitchenPayload({bool isCancellation = false}) {
  return <String, dynamic>{
    'order_number': 'A-100',
    'table_label': 'B2',
    'station_name': 'Hot',
    'created_at': '2026-08-15 12:00',
    'ticket_type': isCancellation ? 'cancellation' : 'new',
    'cancel_reason': isCancellation ? 'Customer changed mind' : null,
    'items': <Map<String, Object?>>[
      <String, Object?>{'quantity': 2, 'name': 'Pho', 'note': 'No onion'},
    ],
  };
}

StorePrintProfile _profile({
  String receiptTemplate = 'modern',
  String kitchenTemplate = 'standard',
  bool showOrderNumber = true,
  bool showTable = true,
  bool showDateTime = true,
  bool showStaffName = true,
  bool showQrCode = false,
  bool showTimeSeated = false,
  String headerTextVi = '',
  String footerTextJa = '',
}) {
  return StorePrintProfile(
    storeName: '',
    storeNameJa: '',
    address: '',
    phone: '',
    taxId: '',
    headerTextVi: headerTextVi,
    footerTextJa: footerTextJa,
    templateSettings: TemplateSettings(
      receiptTemplate: receiptTemplate,
      kitchenTemplate: kitchenTemplate,
      showOrderNumber: showOrderNumber,
      showTable: showTable,
      showDateTime: showDateTime,
      showStaffName: showStaffName,
      showQrCode: showQrCode,
      showTimeSeated: showTimeSeated,
    ),
  );
}

PrinterProfile _usbProfile() => const PrinterProfile(
  id: 'receipt-usb',
  name: 'Receipt USB',
  connectionType: ConnectionType.usb,
  protocol: PrinterProtocol.escpos,
  cupsQueue: 'receipt',
  cupsDeviceUri: 'usb://EPSON/TM-T20III',
  cut: true,
  cashDrawer: true,
);
