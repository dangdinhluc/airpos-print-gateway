import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:qr/qr.dart';

import 'models.dart';
import 'print_profile.dart';

const String defaultUnicodeFontArchivePath =
    '/opt/airpos-print-gateway/fonts/airpos-unicode.fnt.zip';

class RenderedDocument {
  const RenderedDocument({
    required this.bytes,
    required this.raw,
    this.cupsOptions = const <String, String>{},
  });

  final List<int> bytes;
  final bool raw;
  final Map<String, String> cupsOptions;
}

enum TestPrintAction { receipt, kitchen, cut, beep, cashDrawer }

class GatewayPrintRenderer {
  const GatewayPrintRenderer({
    this.unicodeFontArchivePath = defaultUnicodeFontArchivePath,
  });

  final String unicodeFontArchivePath;

  static final Map<String, Future<_LoadedFont>> _fontCache =
      <String, Future<_LoadedFont>>{};
  static final Map<String, _LoadedFont> _fontStatus = <String, _LoadedFont>{};

  String? get fontWarning => _fontStatus[unicodeFontArchivePath]?.warning;

  bool get packagedUnicodeFontAvailable =>
      _fontStatus[unicodeFontArchivePath]?.font != null;

  Future<RenderedDocument> renderTest(
    PrinterProfile profile, {
    TestPrintAction action = TestPrintAction.receipt,
    StorePrintProfile? printProfile,
  }) async {
    final jobType = switch (action) {
      TestPrintAction.receipt => 'receipt',
      TestPrintAction.kitchen => 'kitchen_ticket',
      _ => null,
    };
    final text = switch (action) {
      TestPrintAction.receipt || TestPrintAction.kitchen => renderPreviewText(
        jobType: jobType!,
        payload: samplePayload(jobType: jobType),
        printProfile: printProfile,
      ),
      TestPrintAction.cut => 'AIRPOS CUT TEST',
      TestPrintAction.beep => 'AIRPOS BEEP TEST',
      TestPrintAction.cashDrawer => 'AIRPOS CASH DRAWER TEST',
    };
    return _render(
      profile,
      text,
      action: action,
      qrData: action == TestPrintAction.receipt
          ? _receiptQrData(samplePayload(jobType: jobType!), printProfile)
          : null,
    );
  }

  Future<RenderedDocument> renderJob(
    GatewayJob job,
    PrinterProfile profile, {
    StorePrintProfile? printProfile,
  }) async {
    final type = job.jobType;
    if (type == 'cash_drawer') {
      return _render(
        profile,
        'AIRPOS CASH DRAWER\nJOB ${job.id}',
        action: TestPrintAction.cashDrawer,
      );
    }
    final text = renderPreviewText(
      jobType: type,
      payload: job.payload,
      printProfile: printProfile,
    );
    if (type == 'table_qr') {
      return _render(profile, text, qrData: _qrData(job.payload));
    }
    return _render(
      profile,
      text,
      qrData: _receiptQrData(job.payload, printProfile),
    );
  }

  String renderPreviewText({
    String jobType = 'receipt',
    Map<String, dynamic>? payload,
    StorePrintProfile? printProfile,
  }) {
    final source = payload ?? samplePayload(jobType: jobType);
    return switch (jobType) {
      'cash_drawer' => 'AIRPOS CASH DRAWER',
      'table_qr' => _qrText(
        _value(source, <String>['table_label', 'table_name', 'table_code']),
        _qrData(source),
      ),
      'kitchen_ticket' => _kitchenText(source, printProfile),
      _ => _receiptText(source, printProfile),
    };
  }

  String renderSamplePreviewText({
    String jobType = 'receipt',
    StorePrintProfile? printProfile,
  }) {
    return renderPreviewText(
      jobType: jobType,
      payload: samplePayload(jobType: jobType),
      printProfile: printProfile,
    );
  }

  Map<String, dynamic> samplePayload({String jobType = 'receipt'}) {
    if (jobType == 'kitchen_ticket') {
      return <String, dynamic>{
        'order_number': 'A-100',
        'table_label': 'B2',
        'created_at': '2026-08-15 12:00',
        'items': <Map<String, Object?>>[
          <String, Object?>{'quantity': 2, 'name': 'Pho', 'note': 'No onion'},
        ],
      };
    }
    return <String, dynamic>{
      'order_number': 'A-100',
      'table_label': 'B2',
      'created_at': '2026-08-15 12:00',
      'staff_name': 'Mai',
      'store_settings': <String, Object?>{
        'store_name': 'AirPOS Demo',
        'address': 'Tokyo',
        'phone': '03-0000-0000',
        'currency': 'JPY',
      },
      'items': <Map<String, Object?>>[
        <String, Object?>{'quantity': 2, 'name': 'Pho', 'line_total': 1200},
      ],
      'subtotal': 1200,
      'total': 1200,
      'qr_url': 'https://example.test/review',
    };
  }

  Future<RenderedDocument> _render(
    PrinterProfile profile,
    String text, {
    TestPrintAction? action,
    String? qrData,
  }) async {
    final forceCut = action == TestPrintAction.cut;
    final forceBeep = action == TestPrintAction.beep;
    final openDrawer = action == TestPrintAction.cashDrawer;
    final loadedFont = await _loadFont();
    final printable = loadedFont.font == null ? _ascii(text) : text;
    final bitmap = _renderBitmap(
      printable,
      profile.paperWidthMm == 58 ? 384 : 576,
      font: loadedFont.font ?? image.arial14,
      qrData: qrData,
    );
    if (profile.protocol == PrinterProtocol.starCups) {
      return RenderedDocument(
        bytes: image.encodePng(bitmap),
        raw: false,
        cupsOptions: _starOptions(
          profile,
          cut: forceCut || profile.cut,
          cashDrawer: openDrawer || profile.cashDrawer,
        ),
      );
    }
    return RenderedDocument(
      bytes: _toEscPosRaster(
        bitmap,
        cut: forceCut || profile.cut,
        beep: forceBeep || profile.beep,
        cashDrawer: openDrawer || profile.cashDrawer,
      ),
      raw: true,
    );
  }

  image.Image _renderBitmap(
    String text,
    int width, {
    required image.BitmapFont font,
    String? qrData,
  }) {
    final lines = _wrap(text, width == 384 ? 31 : 46);
    final qrImage = qrData == null || qrData.isEmpty
        ? null
        : _renderQr(qrData, width);
    final lineHeight = font.lineHeight <= 0 ? 20 : font.lineHeight + 6;
    final textHeight = (lines.length * lineHeight) + 20;
    final height =
        textHeight + (qrImage?.height ?? 0) + (qrImage == null ? 0 : 20);
    final canvas = image.Image(width: width, height: height);
    image.fill(canvas, color: image.ColorRgb8(255, 255, 255));
    var y = 8;
    for (final line in lines) {
      image.drawString(
        canvas,
        line,
        font: font,
        x: 8,
        y: y,
        color: image.ColorRgb8(0, 0, 0),
      );
      y += lineHeight;
    }
    if (qrImage != null) {
      image.compositeImage(
        canvas,
        qrImage,
        dstX: ((width - qrImage.width) / 2).round(),
        dstY: y,
      );
    }
    return canvas;
  }

  Future<_LoadedFont> _loadFont() {
    return _fontCache.putIfAbsent(unicodeFontArchivePath, () async {
      final path = unicodeFontArchivePath.trim();
      if (path.isEmpty) {
        final result = const _LoadedFont(
          warning:
              'Unicode font archive path is empty; using ASCII raster font.',
        );
        _fontStatus[unicodeFontArchivePath] = result;
        return result;
      }
      final file = File(path);
      if (!await file.exists()) {
        final result = const _LoadedFont(
          warning:
              'Unicode font archive is not installed; using ASCII raster font.',
        );
        _fontStatus[unicodeFontArchivePath] = result;
        return result;
      }
      try {
        final result = _LoadedFont(
          font: image.BitmapFont.fromZip(await file.readAsBytes()),
        );
        _fontStatus[unicodeFontArchivePath] = result;
        return result;
      } catch (error) {
        final result = _LoadedFont(
          warning: 'Unicode font archive failed to load: $error',
        );
        _fontStatus[unicodeFontArchivePath] = result;
        return result;
      }
    });
  }

  image.Image _renderQr(String value, int width) {
    final qr = QrImage(
      QrCode.fromData(data: value, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    final moduleSize = ((width - 48) / qr.moduleCount).floor().clamp(2, 12);
    final size = qr.moduleCount * moduleSize + 16;
    final canvas = image.Image(width: size, height: size);
    image.fill(canvas, color: image.ColorRgb8(255, 255, 255));
    for (var row = 0; row < qr.moduleCount; row++) {
      for (var col = 0; col < qr.moduleCount; col++) {
        if (!qr.isDark(row, col)) continue;
        image.fillRect(
          canvas,
          x1: 8 + col * moduleSize,
          y1: 8 + row * moduleSize,
          x2: 8 + ((col + 1) * moduleSize) - 1,
          y2: 8 + ((row + 1) * moduleSize) - 1,
          color: image.ColorRgb8(0, 0, 0),
        );
      }
    }
    return canvas;
  }

  List<int> _toEscPosRaster(
    image.Image bitmap, {
    required bool cut,
    required bool beep,
    required bool cashDrawer,
  }) {
    final widthBytes = (bitmap.width + 7) ~/ 8;
    final data = Uint8List(widthBytes * bitmap.height);
    for (var y = 0; y < bitmap.height; y++) {
      for (var x = 0; x < bitmap.width; x++) {
        final pixel = bitmap.getPixel(x, y);
        final luminance =
            (pixel.r * 299 + pixel.g * 587 + pixel.b * 114) / 1000;
        if (luminance < 180) {
          data[y * widthBytes + (x ~/ 8)] |= 0x80 >> (x % 8);
        }
      }
    }
    return <int>[
      0x1B,
      0x40,
      if (beep) ...<int>[0x1B, 0x42, 0x03, 0x02],
      0x1B,
      0x61,
      0x00,
      0x1D,
      0x76,
      0x30,
      0x00,
      widthBytes & 0xFF,
      (widthBytes >> 8) & 0xFF,
      bitmap.height & 0xFF,
      (bitmap.height >> 8) & 0xFF,
      ...data,
      0x0A,
      0x0A,
      if (cashDrawer) ...<int>[0x1B, 0x70, 0x00, 0x32, 0x32],
      if (cut) ...<int>[0x1D, 0x56, 0x42, 0x00],
    ];
  }

  Map<String, String> _starOptions(
    PrinterProfile profile, {
    required bool cut,
    required bool cashDrawer,
  }) {
    return <String, String>{
      if (cut && profile.effectiveCapabilities.cut) 'PageCutType': 'PartialCut',
      if (cashDrawer && profile.effectiveCapabilities.cashDrawer)
        'CashDrawer': 'OpenDrawer1',
    };
  }

  String _receiptText(
    Map<String, dynamic> payload,
    StorePrintProfile? printProfile,
  ) {
    final settings = printProfile?.templateSettings ?? TemplateSettings();
    final store = _storeSettings(payload);
    final order = _order(payload);
    final items = _items(payload);
    final lines = <String>[];
    final storeName = _storeValue(
      printProfile,
      printProfile?.storeName,
      store,
      <String>['store_name', 'brand_name'],
      'AIRPOS',
      defaultLocal: StorePrintProfile().storeName,
    );
    final currency = _storeValue(
      printProfile,
      printProfile?.currency,
      store,
      <String>['currency'],
      'JPY',
    );

    if (settings.receiptTemplate == 'classic') {
      lines
        ..add('*** RECEIPT ***')
        ..add(storeName);
    } else if (settings.receiptTemplate == 'compact') {
      lines.add(
        'RECEIPT #${_field(payload, order, <String>['order_number', 'order_no'])}',
      );
    } else if (settings.receiptTemplate == 'detailed') {
      lines
        ..add(storeName)
        ..add('DETAILED RECEIPT');
    } else {
      lines
        ..add(storeName)
        ..add('RECEIPT');
    }

    _appendStoreLine(
      lines,
      _storeValue(printProfile, printProfile?.storeNameJa, store, <String>[
        'store_name_ja',
      ], ''),
    );
    _appendStoreLine(
      lines,
      _storeValue(printProfile, printProfile?.address, store, <String>[
        'address_ja',
        'address',
      ], ''),
    );
    _appendStoreLine(
      lines,
      _storeValue(printProfile, printProfile?.phone, store, <String>[
        'phone',
        'telephone',
        'hotline',
      ], ''),
    );
    _appendStoreLine(
      lines,
      _storeValue(printProfile, printProfile?.taxId, store, <String>[
        'tax_id',
      ], ''),
    );
    _appendLocalized(lines, printProfile, header: true);

    final meta = <String>[];
    if (settings.showOrderNumber) {
      final value = _field(payload, order, <String>[
        'order_number',
        'order_no',
      ]);
      if (value.isNotEmpty) meta.add('Order: #$value');
    }
    if (settings.showTable) {
      final value = _tableLabel(payload, order);
      if (value.isNotEmpty) meta.add('Table: $value');
    }
    if (settings.showDateTime) {
      final value = _field(payload, order, <String>[
        'paid_at',
        'created_at',
        'updated_at',
      ]);
      if (value.isNotEmpty) meta.add('Date: $value');
    }
    if (settings.showStaffName) {
      final value = _field(payload, order, <String>[
        'cashier_name',
        'staff_name',
        'created_by_name',
      ]);
      if (value.isNotEmpty) meta.add('Cashier: $value');
    }
    if (settings.showTimeSeated) {
      final value = _field(payload, order, <String>['time_seated_minutes']);
      if (value.isNotEmpty) meta.add('Seated: $value min');
    }
    if (settings.receiptTemplate != 'compact') lines.addAll(meta);

    lines.add(_rule(settings.receiptTemplate));
    for (final item in items) {
      lines.add(_receiptItemLine(item, currency));
      final note = _value(item, <String>['note', 'notes', 'modifiers']);
      if (note.isNotEmpty && settings.receiptTemplate == 'detailed') {
        lines.add('  $note');
      }
    }
    lines.add(_rule(settings.receiptTemplate));

    _appendAmount(lines, 'Subtotal', payload, order, <String>[
      'subtotal',
      'sub_total',
    ], currency);
    _appendAmount(lines, 'Discount', payload, order, <String>[
      'discount_amount',
      'discount',
    ], currency);
    _appendAmount(lines, 'Tax', payload, order, <String>[
      'tax_amount',
      'tax',
    ], currency);
    _appendAmount(lines, 'TOTAL', payload, order, <String>[
      'total',
      'grand_total',
      'total_amount',
      'remaining_total',
    ], currency);

    final payments = _payments(payload);
    if (settings.receiptTemplate == 'detailed' && payments.isNotEmpty) {
      lines.add('Payments:');
      for (final payment in payments) {
        final method = _value(payment, <String>['method', 'payment_method']);
        final amount = _amount(
          _value(payment, <String>['amount', 'paid_amount']),
          currency,
        );
        lines.add('  ${method.isEmpty ? 'payment' : method}: $amount');
      }
    }

    final qrData = _receiptQrData(payload, printProfile);
    if (settings.showQrCode && qrData.isNotEmpty) lines.add('QR: $qrData');
    _appendLocalized(lines, printProfile, header: false);
    lines.add('Thank you');
    return lines.where((line) => line.trim().isNotEmpty).join('\n');
  }

  String _kitchenText(
    Map<String, dynamic> payload,
    StorePrintProfile? printProfile,
  ) {
    final settings = printProfile?.templateSettings ?? TemplateSettings();
    final order = _order(payload);
    final cancellation = _isCancellation(payload, order);
    final lines = <String>[];
    if (settings.kitchenTemplate == 'compact') {
      lines.add(
        'KITCHEN #${_field(payload, order, <String>['order_number', 'order_no'])}',
      );
    } else if (settings.kitchenTemplate == 'checklist') {
      lines.add(cancellation ? 'CANCEL CHECKLIST' : 'KITCHEN CHECKLIST');
    } else {
      lines.add(cancellation ? 'CANCEL KITCHEN TICKET' : 'KITCHEN TICKET');
    }
    final station = _field(payload, order, <String>['station_name', 'station']);
    if (station.isNotEmpty) lines.add('Station: $station');
    final table = _tableLabel(payload, order);
    if (settings.showTable && table.isNotEmpty) lines.add('Table: $table');
    if (settings.showOrderNumber) {
      final number = _field(payload, order, <String>[
        'order_number',
        'order_no',
      ]);
      if (number.isNotEmpty && settings.kitchenTemplate != 'compact') {
        lines.add('Order: #$number');
      }
    }
    if (settings.showDateTime) {
      final value = _field(payload, order, <String>[
        'created_at',
        'updated_at',
      ]);
      if (value.isNotEmpty) lines.add('Time: $value');
    }
    lines.add(_rule(settings.kitchenTemplate));
    for (final item in _items(payload)) {
      final quantity = _value(item, <String>['quantity', 'qty']);
      final name = _value(item, <String>['name', 'product_name', 'item_name']);
      final prefix = settings.kitchenTemplate == 'checklist' ? '[ ] ' : '';
      lines.add('$prefix${quantity.isEmpty ? '1' : quantity} x $name');
      final note = _value(item, <String>['note', 'notes', 'modifiers']);
      if (note.isNotEmpty && settings.kitchenTemplate != 'compact') {
        lines.add('  $note');
      }
    }
    final reason = _dynamicValue(payload, <String>[
      'cancel_reason',
      'reason',
      'note',
    ]);
    if (cancellation && reason.isNotEmpty) lines.add('CANCEL: $reason');
    return lines.where((line) => line.trim().isNotEmpty).join('\n');
  }

  String _qrText(String title, String url) =>
      <String>[if (title.isNotEmpty) title, 'SCAN QR FOR MENU', url].join('\n');

  List<String> _wrap(String value, int width) {
    final result = <String>[];
    for (final line in value.split('\n')) {
      if (line.length <= width) {
        result.add(line);
        continue;
      }
      for (var offset = 0; offset < line.length; offset += width) {
        result.add(
          line.substring(offset, (offset + width).clamp(0, line.length)),
        );
      }
    }
    return result.isEmpty ? <String>[' '] : result;
  }
}

class _LoadedFont {
  const _LoadedFont({this.font, this.warning});

  final image.BitmapFont? font;
  final String? warning;
}

String _ascii(String value) {
  final buffer = StringBuffer();
  for (final unit
      in value.replaceAll('Đ', 'D').replaceAll('đ', 'd').codeUnits) {
    buffer.write(unit <= 0x7F ? String.fromCharCode(unit) : '?');
  }
  return buffer.toString();
}

Map<String, dynamic> _snapshot(Map<String, dynamic> payload) =>
    _map(payload, <String>['receipt_snapshot', 'snapshot']);

Map<String, dynamic> _order(Map<String, dynamic> payload) {
  final snapshot = _snapshot(payload);
  final nested = _map(snapshot, <String>['order']);
  if (nested.isNotEmpty) return nested;
  final root = _map(payload, <String>['order']);
  if (root.isNotEmpty) return root;
  return snapshot.isEmpty ? payload : snapshot;
}

Map<String, dynamic> _storeSettings(Map<String, dynamic> payload) {
  final snapshot = _snapshot(payload);
  final root = _map(payload, <String>['store_settings', 'storeSettings']);
  if (root.isNotEmpty) return root;
  return _map(snapshot, <String>['store_settings', 'storeSettings']);
}

List<Map<String, dynamic>> _items(Map<String, dynamic> payload) {
  final snapshot = _snapshot(payload);
  final order = _order(payload);
  for (final pair in <(Map<String, dynamic>, String)>[
    (payload, 'items'),
    (snapshot, 'items'),
    (order, 'items'),
    (payload, 'order_items'),
    (snapshot, 'order_items'),
  ]) {
    final items = _list(pair.$1, pair.$2);
    if (items.isNotEmpty) return items;
  }
  return <Map<String, dynamic>>[];
}

List<Map<String, dynamic>> _payments(Map<String, dynamic> payload) {
  final snapshot = _snapshot(payload);
  final order = _order(payload);
  for (final pair in <(Map<String, dynamic>, String)>[
    (payload, 'payments'),
    (snapshot, 'payments'),
    (order, 'payments'),
  ]) {
    final payments = _list(pair.$1, pair.$2);
    if (payments.isNotEmpty) return payments;
  }
  return <Map<String, dynamic>>[];
}

String _field(
  Map<String, dynamic> payload,
  Map<String, dynamic> order,
  List<String> keys,
) {
  final root = _value(payload, keys);
  if (root.isNotEmpty) return root;
  final orderValue = _value(order, keys);
  if (orderValue.isNotEmpty) return orderValue;
  final table = _map(order, <String>['table']);
  return _value(table, keys);
}

String _dynamicValue(Map<String, dynamic> payload, List<String> keys) {
  final snapshot = _snapshot(payload);
  final order = _order(payload);
  for (final map in <Map<String, dynamic>>[payload, snapshot, order]) {
    final value = _value(map, keys);
    if (value.isNotEmpty) return value;
  }
  return '';
}

String _tableLabel(Map<String, dynamic> payload, Map<String, dynamic> order) {
  final table = _map(order, <String>['table']);
  final root = _value(payload, <String>[
    'table_label',
    'table_name',
    'table_code',
  ]);
  if (root.isNotEmpty) return root;
  final orderValue = _value(order, <String>[
    'table_label',
    'table_name',
    'table_code',
  ]);
  if (orderValue.isNotEmpty) return orderValue;
  return _value(table, <String>['label', 'name', 'code']);
}

String _storeValue(
  StorePrintProfile? profile,
  String? local,
  Map<String, dynamic> store,
  List<String> keys,
  String fallback, {
  String defaultLocal = '',
}) {
  final payload = _value(store, keys);
  final text = local?.trim() ?? '';
  final normalizedDefault = defaultLocal.trim();
  if (profile != null &&
      text.isNotEmpty &&
      !((text == fallback || text == normalizedDefault) &&
          payload.isNotEmpty)) {
    return text;
  }
  return payload.isNotEmpty ? payload : fallback;
}

void _appendStoreLine(List<String> lines, String? value) {
  final text = value?.trim() ?? '';
  if (text.isNotEmpty) lines.add(text);
}

void _appendLocalized(
  List<String> lines,
  StorePrintProfile? profile, {
  required bool header,
}) {
  if (profile == null) return;
  final settings = profile.templateSettings;
  if (settings.languages.contains('vi')) {
    _appendStoreLine(
      lines,
      header ? profile.headerTextVi : profile.footerTextVi,
    );
  }
  if (settings.languages.contains('ja')) {
    _appendStoreLine(
      lines,
      header ? profile.headerTextJa : profile.footerTextJa,
    );
  }
}

void _appendAmount(
  List<String> lines,
  String label,
  Map<String, dynamic> payload,
  Map<String, dynamic> order,
  List<String> keys,
  String currency,
) {
  final value = _field(payload, order, keys);
  if (value.isNotEmpty) lines.add('$label: ${_amount(value, currency)}');
}

String _receiptItemLine(Map<String, dynamic> item, String currency) {
  final name = _value(item, <String>['name', 'product_name', 'item_name']);
  final quantity = _value(item, <String>['quantity', 'qty']);
  final total = _value(item, <String>[
    'line_total',
    'line_subtotal',
    'total',
    'subtotal',
  ]);
  return '${quantity.isEmpty ? '1' : quantity} x $name${total.isEmpty ? '' : '  ${_amount(total, currency)}'}';
}

String _amount(String value, String currency) {
  final text = value.trim();
  if (text.isEmpty) return '';
  if (RegExp(r'[^0-9.-]').hasMatch(text)) return text;
  final number = num.tryParse(text);
  if (number == null) return text;
  final symbol = switch (currency.trim().toUpperCase()) {
    'JPY' => 'JPY ',
    'VND' => 'VND ',
    'USD' => 'USD ',
    _ => '${currency.trim().toUpperCase()} ',
  };
  return '$symbol${number.round()}';
}

String _receiptQrData(
  Map<String, dynamic> payload,
  StorePrintProfile? printProfile,
) {
  final settings = printProfile?.templateSettings ?? TemplateSettings();
  if (!settings.showQrCode) return '';
  return _dynamicValue(payload, <String>[
    'qr_url',
    'review_qr_url',
    'review_url',
    'receipt_qr_url',
  ]);
}

String _qrData(Map<String, dynamic> payload) =>
    _dynamicValue(payload, <String>['qr_url', 'url', 'tablet_url']);

String _rule(String template) => template == 'compact'
    ? '----------------'
    : '--------------------------------';

bool _isTrue(Object? value) =>
    value == true || value?.toString().trim().toLowerCase() == 'true';

bool _isCancellation(Map<String, dynamic> payload, Map<String, dynamic> order) {
  if (_isTrue(payload['is_cancellation']) ||
      _isTrue(order['is_cancellation'])) {
    return true;
  }
  final type = _dynamicValue(payload, <String>['ticket_type', 'type']);
  return type.toLowerCase() == 'cancellation';
}

String _value(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty && text != 'null') return text;
  }
  return '';
}

Map<String, dynamic> _map(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is Map) return Map<String, dynamic>.from(value);
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _list(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) return <Map<String, dynamic>>[];
  return value
      .whereType<Map<Object?, Object?>>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}
