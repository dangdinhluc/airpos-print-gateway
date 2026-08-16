import 'dart:io';

import 'package:airpos_print_gateway_core/src/android_template.dart';
import 'package:airpos_print_gateway_core/src/escpos.dart';
import 'package:airpos_print_gateway_core/src/models.dart';
import 'package:airpos_print_gateway_core/src/print_profile.dart';
import 'package:test/test.dart';

void main() {
  const renderer = GatewayPrintRenderer(unicodeFontArchivePath: '');

  group('receipt preview presets', () {
    test('modern preset follows Android detailed baseline', () {
      final text = renderer.renderPreviewText(
        payload: _receiptPayload(),
        printProfile: _profile(
          receiptTemplate: 'modern',
          headerTextVi: 'Xin chao',
          footerTextJa: 'Arigato',
        ),
      );

      expect(text, contains('Payload Store'));
      expect(text, contains('\u0002\u0003\u0006Payload Store'));
      expect(text, contains('Món / 商品'));
      expect(text, contains('10%対象'));
      expect(text, isNot(contains('Xin chao')));
      expect(text, contains('Arigato'));
    });

    test('classic preset renders classic title', () {
      final text = renderer.renderPreviewText(
        payload: _receiptPayload(),
        printProfile: _profile(receiptTemplate: 'classic'),
      );

      expect(text, contains('\u0001Payload Store'));
      expect(text, contains('RECEIPT'));
      expect(text, contains('Món / 商品'));
    });

    test(
      'compact preset keeps compact header and suppresses metadata block',
      () {
        final text = renderer.renderPreviewText(
          payload: _receiptPayload(),
          printProfile: _profile(receiptTemplate: 'compact'),
        );

        expect(text, contains('\u0001Payload Store'));
        expect(text, contains('#A-100'));
        expect(text, isNot(contains('Order: #A-100')));
        expect(text, isNot(contains('Cashier: Mai')));
        expect(text, contains('2 x Pho'));
      },
    );

    test('detailed preset includes notes and payments', () {
      final text = renderer.renderPreviewText(
        payload: _receiptPayload(),
        printProfile: _profile(receiptTemplate: 'detailed'),
      );

      expect(text, contains('\u0002\u0003\u0006Payload Store'));
      expect(text, contains('No onion'));
      expect(text, contains('現金 (Tiền mặt)'));
      expect(text, contains('¥1,200'));
    });
  });

  group('kitchen preview presets', () {
    test('standard preset renders kitchen ticket title', () {
      final text = renderer.renderPreviewText(
        jobType: 'kitchen_ticket',
        payload: _kitchenPayload(),
        printProfile: _profile(kitchenTemplate: 'standard'),
      );

      expect(text, contains('\u0001B2'));
      expect(text, contains('#A-100'));
      expect(text, contains('No onion'));
    });

    test('compact preset keeps the compact kitchen layout', () {
      final text = renderer.renderPreviewText(
        jobType: 'kitchen_ticket',
        payload: _kitchenPayload(),
        printProfile: _profile(kitchenTemplate: 'compact'),
      );

      expect(text, contains('\u0001B2  新規'));
      expect(text, contains('Order'));
      expect(text, contains('No onion'));
    });

    test('checklist preset uses checklist markers and cancellation title', () {
      final text = renderer.renderPreviewText(
        jobType: 'kitchen_ticket',
        payload: _kitchenPayload(isCancellation: true),
        printProfile: _profile(kitchenTemplate: 'checklist'),
      );

      expect(text, contains('CANCEL'));
      expect(text, contains('[X] HUY 2 Pho'));
      expect(text, contains('NOTE: Customer changed mind'));
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
      expect(text, contains('Footer JA'));
      expect(text, contains('[ QR menu / QRメニュー ]'));
      expect(text, isNot(contains('Header VI')));
      expect(text, isNot(contains('42 phút')));
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
    expect(text, contains('No. N-77'));
    expect(text, contains('担当: Nested Staff'));
    expect(text, contains('Tea'));
    expect(text, contains('Less ice'));
    expect(text, contains('9.00 USD'));
    expect(text, contains('[ QR menu / QRメニュー ]'));
    expect(text, isNot(contains('https://example.test/nested')));
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

  test(
    'receipt item detail keeps quantity and unit price together on left',
    () {
      final text = renderer.renderPreviewText(
        payload: <String, dynamic>{
          'items': <Map<String, Object?>>[
            <String, Object?>{'name': 'チロック', 'quantity': 1, 'line_total': 430},
          ],
        },
        printProfile: _profile(receiptTemplate: 'detailed'),
      );
      expect(text, contains('\n1 x ¥430\n'));
    },
  );

  test('receipt amount column separates text from yen value', () {
    expect(splitReceiptAmountColumn('小計                         ¥1,480'), (
      '小計',
      '¥1,480',
    ));
    expect(splitReceiptAmountColumn('消費税(10%)                    ¥135'), (
      '消費税(10%)',
      '¥135',
    ));
    expect(splitReceiptAmountColumn('¥1,480'), isNull);
  });

  test(
    'Wabi Japanese receipt preview keeps receipt fields and aligned totals',
    () {
      final text = renderer.renderPreviewText(
        payload: <String, dynamic>{
          'order_number': '20260815-F5F183',
          'table_label': 'B1',
          'created_at': '2026/08/15 22:56',
          'store_settings': <String, Object?>{
            'store_name': 'ワビ酒場高松',
            'address': '香川県高松市瓦町',
            'phone': '087-800-8150',
            'currency': 'JPY',
          },
          'items': <Map<String, Object?>>[
            <String, Object?>{
              'quantity': 1,
              'name': 'Ikan Gulai',
              'line_total': 1480,
            },
            <String, Object?>{
              'quantity': 1,
              'name': 'Bolu Pisang',
              'line_total': 430,
            },
          ],
          'subtotal': 1910,
          'tax': 174,
          'total': 1910,
        },
        printProfile: _profile(receiptTemplate: 'detailed'),
      );

      expect(text, contains('ワビ酒場高松'));
      expect(text, contains('香川県高松市瓦町'));
      expect(text, contains('087-800-8150'));
      expect(text, contains('Ikan Gulai'));
      expect(text, contains('¥1,910'));
    },
  );

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
    'receipt uses Android QR marker while table QR keeps raster payload',
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
      final tableQr = await renderer.renderJob(
        const GatewayJob(
          id: 'table-qr',
          jobType: 'table_qr',
          payload: <String, dynamic>{
            'table_label': 'B2',
            'qr_url': 'https://example.test/table/B2',
          },
        ),
        _usbProfile(),
      );
      final withQrText = renderer.renderPreviewText(
        payload: _receiptPayload(),
        printProfile: _profile(showQrCode: true),
      );

      expect(withQr.raw, isTrue);
      expect(withQr.bytes, containsAllInOrder(<int>[0x1B, 0x40, 0x1B, 0x61]));
      expect(
        withQr.bytes,
        containsAllInOrder(<int>[0x1B, 0x70, 0x00, 0x32, 0x32]),
      );
      expect(withQr.bytes, containsAllInOrder(<int>[0x1D, 0x56, 0x42, 0x00]));
      expect(withQrText, contains('[ QR menu / QRメニュー ]'));
      expect(withQrText, isNot(contains('https://example.test/review')));
      expect(withoutQr.bytes.length, greaterThan(100));
      expect(tableQr.bytes.length, greaterThan(1000));

      expect(cashDrawer.raw, isTrue);
      expect(
        cashDrawer.bytes,
        containsAllInOrder(<int>[0x1B, 0x70, 0x00, 0x32, 0x32]),
      );
    },
  );

  test('kitchen ticket splits one item per page like Android', () async {
    final document = await renderer.renderJob(
      const GatewayJob(
        id: 'kitchen-pages',
        jobType: 'kitchen_ticket',
        payload: <String, dynamic>{
          'order_number': 'A-100',
          'table_label': 'B2',
          'items': <Map<String, Object?>>[
            <String, Object?>{'quantity': 1, 'name': 'Pho'},
            <String, Object?>{'quantity': 2, 'name': 'Tea'},
          ],
        },
      ),
      _usbProfile(),
    );

    expect(document.pages, hasLength(2));
    expect(document.printablePages, hasLength(2));
  });

  test('uses Android 58mm and 80mm raster widths', () async {
    final wide = await renderer.renderJob(
      GatewayJob(
        id: 'wide',
        jobType: 'receipt',
        payload: renderer.samplePayload(jobType: 'receipt'),
      ),
      _usbProfile(),
    );
    final narrow = await renderer.renderJob(
      GatewayJob(
        id: 'narrow',
        jobType: 'receipt',
        payload: renderer.samplePayload(jobType: 'receipt'),
      ),
      _usbProfile().copyWith(paperWidthMm: 58),
    );

    expect(wide.bytes[9], 72); // 576 dots / 8
    expect(narrow.bytes[9], 48); // 384 dots / 8
  });
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
