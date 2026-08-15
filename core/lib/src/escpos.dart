import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:qr/qr.dart';

import 'models.dart';

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
  const GatewayPrintRenderer();

  Future<RenderedDocument> renderTest(
    PrinterProfile profile, {
    TestPrintAction action = TestPrintAction.receipt,
  }) async {
    final text = switch (action) {
      TestPrintAction.receipt => _testText(profile, 'TEST RECEIPT'),
      TestPrintAction.kitchen => _testText(profile, 'TEST KITCHEN'),
      TestPrintAction.cut => 'AIRPOS CUT TEST',
      TestPrintAction.beep => 'AIRPOS BEEP TEST',
      TestPrintAction.cashDrawer => 'AIRPOS CASH DRAWER TEST',
    };
    return _render(profile, text, action: action);
  }

  Future<RenderedDocument> renderJob(
    GatewayJob job,
    PrinterProfile profile,
  ) async {
    final type = job.jobType;
    if (type == 'cash_drawer') {
      return _render(
        profile,
        'AIRPOS CASH DRAWER\nJOB ${job.id}',
        action: TestPrintAction.cashDrawer,
      );
    }
    if (type == 'table_qr') {
      final url = _value(job.payload, <String>['qr_url', 'url']);
      final title = _value(job.payload, <String>[
        'table_label',
        'table_name',
        'table_code',
      ]);
      return _render(profile, _qrText(title, url), qrData: url);
    }
    if (type == 'kitchen_ticket') {
      return _render(profile, _kitchenText(job.payload));
    }
    return _render(profile, _receiptText(job.payload));
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
    final printable = _ascii(text);
    final bitmap = _renderBitmap(
      printable,
      profile.paperWidthMm == 58 ? 384 : 576,
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

  image.Image _renderBitmap(String text, int width, {String? qrData}) {
    final lines = _wrap(text, width == 384 ? 31 : 46);
    final qrImage = qrData == null || qrData.isEmpty
        ? null
        : _renderQr(qrData, width);
    final textHeight = (lines.length * 20) + 20;
    final height =
        textHeight + (qrImage?.height ?? 0) + (qrImage == null ? 0 : 20);
    final canvas = image.Image(width: width, height: height);
    image.fill(canvas, color: image.ColorRgb8(255, 255, 255));
    var y = 8;
    for (final line in lines) {
      image.drawString(
        canvas,
        line,
        font: image.arial14,
        x: 8,
        y: y,
        color: image.ColorRgb8(0, 0, 0),
      );
      y += 20;
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
    // Star's CUPS PPD owns the option names; values stay fixed and are never
    // accepted from a server payload.
    return <String, String>{
      if (cut && profile.effectiveCapabilities.cut) 'PageCutType': 'PartialCut',
      if (cashDrawer && profile.effectiveCapabilities.cashDrawer)
        'CashDrawer': 'OpenDrawer1',
    };
  }

  String _testText(PrinterProfile profile, String title) => <String>[
    'AIRPOS PRINT GATEWAY',
    title,
    'Connection: ${profile.connectionType.value}',
    'Protocol: ${profile.protocol.value}',
    'Paper: ${profile.paperWidthMm}mm',
    'Queue: ${profile.cupsQueue ?? '-'}',
  ].join('\n');

  String _receiptText(Map<String, dynamic> payload) {
    final store = _map(payload, <String>['store_settings', 'storeSettings']);
    final order = _map(payload, <String>['order', 'receipt_snapshot']);
    final items = _list(payload, 'items');
    final lines = <String>[
      _value(store, <String>['store_name', 'brand_name']).isEmpty
          ? 'AIRPOS'
          : _value(store, <String>['store_name', 'brand_name']),
      'RECEIPT #${_value(payload, <String>['order_number'])}',
      'Table: ${_value(payload, <String>['table_label', 'table_name'])}',
      '--------------------------------',
    ];
    for (final item in items) {
      final name = _value(item, <String>['name', 'product_name', 'item_name']);
      final quantity = _value(item, <String>['quantity', 'qty']);
      final total = _value(item, <String>['line_total', 'total', 'subtotal']);
      lines.add('$quantity x $name${total.isEmpty ? '' : '  $total'}');
    }
    final total = _value(payload, <String>['total', 'grand_total']).isEmpty
        ? _value(order, <String>['total', 'grand_total'])
        : _value(payload, <String>['total', 'grand_total']);
    lines
      ..add('--------------------------------')
      ..add('TOTAL: $total')
      ..add('Thank you');
    return lines.join('\n');
  }

  String _kitchenText(Map<String, dynamic> payload) {
    final lines = <String>[
      'KITCHEN',
      _value(payload, <String>['station_name', 'station']),
      'Table: ${_value(payload, <String>['table_label', 'table_name', 'table_code'])}',
      'Order: ${_value(payload, <String>['order_number', 'order_no'])}',
      '--------------------------------',
    ];
    for (final item in _list(payload, 'items')) {
      final quantity = _value(item, <String>['quantity', 'qty']);
      final name = _value(item, <String>['name', 'product_name', 'item_name']);
      lines.add('$quantity x $name');
      final note = _value(item, <String>['note', 'notes', 'modifiers']);
      if (note.isNotEmpty) lines.add('  $note');
    }
    final reason = _value(payload, <String>['cancel_reason', 'note']);
    if (payload['is_cancellation'] == true && reason.isNotEmpty) {
      lines.add('CANCEL: $reason');
    }
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

String _ascii(String value) {
  final buffer = StringBuffer();
  for (final unit
      in value.replaceAll('Đ', 'D').replaceAll('đ', 'd').codeUnits) {
    buffer.write(unit <= 0x7F ? String.fromCharCode(unit) : '?');
  }
  return buffer.toString();
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
