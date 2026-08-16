import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'android_template.dart';
import 'models.dart';
import 'print_profile.dart';

const String defaultUnicodeFontArchivePath =
    '/opt/airpos-print-gateway/fonts/airpos-unicode.fnt.zip';

class RenderedDocument {
  const RenderedDocument({
    required this.bytes,
    required this.raw,
    this.cupsOptions = const <String, String>{},
    this.pages = const <RenderedDocument>[],
  });

  final List<int> bytes;
  final bool raw;
  final Map<String, String> cupsOptions;
  final List<RenderedDocument> pages;

  Iterable<RenderedDocument> get printablePages =>
      pages.isEmpty ? <RenderedDocument>[this] : pages;
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
        paperWidthMm: profile.paperWidthMm,
      ),
      TestPrintAction.cut => 'AIRPOS CUT TEST',
      TestPrintAction.beep => 'AIRPOS BEEP TEST',
      TestPrintAction.cashDrawer => 'AIRPOS CASH DRAWER TEST',
    };
    return _render(profile, text, action: action);
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
    final fallbackOrderNumber = job.orderId ?? '';
    final renderPayload =
        type == 'kitchen_ticket' &&
            job.createdAt != null &&
            job.createdAt!.trim().isNotEmpty &&
            !job.payload.containsKey('created_at')
        ? (Map<String, dynamic>.from(job.payload)
            ..['printed_at'] = job.createdAt)
        : job.payload;
    final text = renderPreviewText(
      jobType: type,
      payload: renderPayload,
      printProfile: printProfile,
      paperWidthMm: profile.paperWidthMm,
      fallbackOrderNumber: fallbackOrderNumber,
    );

    final rawItems = renderPayload['items'];
    final splitKitchen =
        type == 'kitchen_ticket' &&
        rawItems is List &&
        rawItems.length > 1 &&
        (job.payload['one_item_per_ticket'] == null ||
            job.payload['one_item_per_ticket'] == true ||
            job.payload['one_item_per_ticket'].toString().toLowerCase() ==
                'true');
    if (splitKitchen) {
      final pages = <RenderedDocument>[];
      final pageProfile = profile.copyWith(cut: true);
      for (final rawItem in rawItems) {
        if (rawItem is! Map) continue;
        final pagePayload = Map<String, dynamic>.from(renderPayload)
          ..['items'] = <Object?>[rawItem];
        final pageText = renderPreviewText(
          jobType: type,
          payload: pagePayload,
          printProfile: printProfile,
          paperWidthMm: profile.paperWidthMm,
          fallbackOrderNumber: fallbackOrderNumber,
        );
        pages.add(await _render(pageProfile, pageText));
      }
      if (pages.isNotEmpty) {
        return RenderedDocument(
          bytes: pages.first.bytes,
          raw: pages.first.raw,
          cupsOptions: pages.first.cupsOptions,
          pages: pages,
        );
      }
    }

    if (type == 'table_qr') {
      return _render(profile, text, qrData: _qrData(job.payload));
    }
    return _render(profile, text);
  }

  String renderPreviewText({
    String jobType = 'receipt',
    Map<String, dynamic>? payload,
    StorePrintProfile? printProfile,
    int paperWidthMm = 80,
    String fallbackOrderNumber = '',
  }) {
    final source = payload ?? samplePayload(jobType: jobType);
    final width = paperWidthMm == 58 ? 29 : 38;
    return switch (jobType) {
      'cash_drawer' => 'AIRPOS CASH DRAWER',
      'table_qr' => _qrText(
        _value(source, <String>['table_label', 'table_name', 'table_code']),
        _qrData(source),
      ),
      'kitchen_ticket' => AndroidPrintTemplate.kitchen(
        source,
        printProfile,
        width: width,
        fallbackOrderNumber: fallbackOrderNumber,
      ),
      _ => AndroidPrintTemplate.receipt(
        source,
        printProfile,
        width: width,
        fallbackOrderNumber: fallbackOrderNumber,
      ),
    };
  }

  String renderSamplePreviewText({
    String jobType = 'receipt',
    StorePrintProfile? printProfile,
    int paperWidthMm = 80,
  }) {
    return renderPreviewText(
      jobType: jobType,
      payload: samplePayload(jobType: jobType),
      printProfile: printProfile,
      paperWidthMm: paperWidthMm,
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
    final loadedFont = await _loadFont();
    final printable = loadedFont.font == null ? _ascii(text) : text;
    final bitmap = _binarize(
      _renderBitmap(
        printable,
        profile.paperWidthMm == 58 ? 384 : 576,
        font: loadedFont.font ?? image.arial14,
        qrData: qrData,
      ),
    );
    final forceCut = action == TestPrintAction.cut;
    final forceBeep = action == TestPrintAction.beep;
    final openDrawer = action == TestPrintAction.cashDrawer;
    if (profile.protocol == PrinterProtocol.starCups) {
      return RenderedDocument(
        bytes: image.encodePng(bitmap),
        raw: false,
        cupsOptions: _starOptions(
          profile,
          bitmapHeight: bitmap.height,
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
    return renderAndroidTemplateBitmap(text, width, font: font, qrData: qrData);
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

  image.Image _binarize(image.Image source) {
    for (final pixel in source) {
      final luminance = (pixel.r * 299 + pixel.g * 587 + pixel.b * 114) ~/ 1000;
      final value = luminance < 160 ? 0 : 255;
      pixel
        ..r = value
        ..g = value
        ..b = value
        ..a = 255;
    }
    return source;
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
    required int bitmapHeight,
    required bool cut,
    required bool cashDrawer,
  }) {
    return <String, String>{
      'orientation-requested': '3',
      'media':
          'Custom.${profile.paperWidthMm == 58 ? 48 : 72}x${(bitmapHeight * 25.4 / 203).ceil()}mm',
      if (cut && profile.effectiveCapabilities.cut) 'PageCutType': 'PartialCut',
      if (cashDrawer && profile.effectiveCapabilities.cashDrawer)
        'CashDrawer': 'OpenDrawer1',
    };
  }

  String _qrText(String title, String url) =>
      <String>[if (title.isNotEmpty) title, 'SCAN QR FOR MENU', url].join('\n');
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

String _value(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty && text.toLowerCase() != 'null') return text;
  }
  return '';
}

String _qrData(Map<String, dynamic> payload) {
  final snapshot = payload['receipt_snapshot'];
  final nested = snapshot is Map
      ? Map<String, dynamic>.from(snapshot)
      : <String, dynamic>{};
  return _value(payload, <String>['qr_url', 'url', 'tablet_url']).isNotEmpty
      ? _value(payload, <String>['qr_url', 'url', 'tablet_url'])
      : _value(nested, <String>['qr_url', 'url', 'tablet_url']);
}
