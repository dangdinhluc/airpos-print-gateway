import 'dart:math' as math;

import 'package:image/image.dart' as image;
import 'package:qr/qr.dart';

import 'print_profile.dart';

const String androidBigLineMarker = '\u0001';
const String androidSansMarker = '\u0002';
const String androidTitleMarker = '\u0003';
const String androidSmallMarker = '\u0004';
const String androidInvertMarker = '\u0005';
const String androidCenterMarker = '\u0006';
const String androidRuleMarker = '\u0007';
const String androidMediumMarker = '\u0008';

const Set<String> androidStyleMarkers = <String>{
  androidBigLineMarker,
  androidSansMarker,
  androidTitleMarker,
  androidSmallMarker,
  androidInvertMarker,
  androidCenterMarker,
  androidRuleMarker,
  androidMediumMarker,
};

class AndroidPrintTemplate {
  const AndroidPrintTemplate._();

  static String receipt(
    Map<String, dynamic> payload,
    StorePrintProfile? profile, {
    required int width,
    String fallbackOrderNumber = '',
  }) {
    final snapshot = _map(payload, <String>['receipt_snapshot', 'snapshot']);
    final order = _order(payload, snapshot);
    final items = _items(payload, snapshot, order);
    final storeSettings = _firstMap(<Map<String, dynamic>>[
      _map(snapshot, <String>['storeSettings', 'store_settings']),
      _map(payload, <String>['storeSettings', 'store_settings']),
    ]);
    final receiptSettings = _firstMap(<Map<String, dynamic>>[
      _map(snapshot, <String>['receiptSettings', 'receipt_settings']),
      _map(payload, <String>['receiptSettings', 'receipt_settings']),
    ]);
    final printerSettings = _firstMap(<Map<String, dynamic>>[
      _map(snapshot, <String>['printerSettings', 'printer_settings']),
      _map(payload, <String>['printerSettings', 'printer_settings']),
    ]);
    final settings = profile?.templateSettings ?? TemplateSettings();
    final documentType = _firstNonBlank(<String>[
      _value(snapshot, <String>['documentType', 'document_type']),
      _value(payload, <String>['documentType', 'document_type']),
    ]).toLowerCase();
    final isRyoushuusho = documentType == 'ryoushuusho';
    final payloadLanguages = _languages(receiptSettings['languages']);
    final languages = isRyoushuusho
        ? <String>['ja']
        : (payloadLanguages.isNotEmpty
              ? payloadLanguages
              : (settings.languages.isEmpty
                    ? <String>['vi', 'ja']
                    : settings.languages));

    final storeNameJa = _localOrPayload(
      profile?.storeNameJa,
      storeSettings,
      <String>['store_name_ja'],
      '',
    );
    final storeNameVi = _localOrPayload(
      profile?.storeName,
      storeSettings,
      <String>['store_name', 'brand_name'],
      'HYBRID POS',
    );
    final showVi = languages.contains('vi');
    final showJa = languages.contains('ja');
    final storeName = showVi || !showJa || storeNameJa.isEmpty
        ? _firstNonBlank(<String>[storeNameVi, storeNameJa, 'HYBRID POS'])
        : _firstNonBlank(<String>[storeNameJa, storeNameVi, 'HYBRID POS']);
    final storeNameSecondary =
        showJa && storeNameJa.isNotEmpty && storeNameJa != storeName
        ? storeNameJa
        : (showVi && storeNameVi.isNotEmpty && storeNameVi != storeName
              ? storeNameVi
              : '');
    final storeAddress = _localOrPayload(
      profile?.address,
      storeSettings,
      <String>['address_ja', 'address'],
      '',
    );
    final storePhone = _localOrPayload(profile?.phone, storeSettings, <String>[
      'phone',
      'telephone',
      'hotline',
    ], '');
    final storeTaxId = _localOrPayload(profile?.taxId, storeSettings, <String>[
      'tax_id',
    ], '');
    final currency = _localOrPayload(profile?.currency, storeSettings, <String>[
      'currency',
    ], 'JPY');
    final profileHeaderLines = _localizedProfileLines(
      profile?.headerTextVi ?? '',
      profile?.headerTextJa ?? '',
      languages,
    );
    final headerLines =
        (profileHeaderLines.isNotEmpty
                ? profileHeaderLines
                : _localizedPayloadLines(
                    receiptSettings,
                    'header_text',
                    languages,
                  ))
            .where((line) => !_isGenericReceiptHeaderLine(line))
            .toList();
    final profileFooterLines = _localizedProfileLines(
      profile?.footerTextVi ?? '',
      profile?.footerTextJa ?? '',
      languages,
    );
    final footerLines = profileFooterLines.isNotEmpty
        ? profileFooterLines
        : _localizedPayloadLines(receiptSettings, 'footer_text', languages);
    final orderNumber = _firstNonBlank(<String>[
      _value(order, <String>['order_number', 'order_no']),
      fallbackOrderNumber,
    ]);
    final table = _firstMap(<Map<String, dynamic>>[
      _map(snapshot, <String>['table']),
      _map(order, <String>['table']),
      _map(payload, <String>['table']),
    ]);
    final tableName = _firstNonBlank(<String>[
      _value(order, <String>['table_name']),
      _value(table, <String>['name']),
    ]);
    final tableNumber = _firstNonBlank(<String>[
      _value(order, <String>['table_number']),
      _value(table, <String>['code']),
    ]);
    final tableLabel = tableName.isNotEmpty
        ? tableName
        : (tableNumber.isNotEmpty ? '#$tableNumber' : '');
    final printedAt = _formatPrintDate(
      _firstNonBlank(<String>[
        _value(order, <String>['paid_at']),
        _value(order, <String>['created_at']),
      ]),
    );
    final staffName = _firstNonBlank(<String>[
      _value(order, <String>['cashier_name']),
      _value(order, <String>['staff_name']),
      _value(order, <String>['user_name']),
    ]);
    final subtotal = _valueAsMoney(order['subtotal'], currency);
    final discount = _valueAsMoney(order['discount_amount'], currency);
    final surcharge = _valueAsMoney(order['surcharge_amount'], currency);
    final total = _firstNonBlank(<String>[
      _valueAsMoney(order['total'], currency),
      _valueAsMoney(payload['total'], currency),
    ]);
    final seatedMinutes = _durationMinutes(order['time_seated_minutes']);
    final seatedDuration = seatedMinutes == null
        ? ''
        : _formatReceiptDuration(seatedMinutes, languages);
    final totalNumeric =
        _numeric(order['total']) ?? _numeric(payload['total']) ?? 0;
    final guestNumeric =
        _numeric(payload['guest_count']) ??
        _numeric(order['guest_count']) ??
        _numeric(table['guest_count']);
    final guestLabel = guestNumeric != null && guestNumeric > 0
        ? '${guestNumeric.toInt()}名'
        : '';
    final tax = _computeInclusiveTax(totalNumeric, currency, languages);
    final paymentRows = _paymentRows(payload, currency, languages);
    final model = _ReceiptModel(
      width: width,
      storeName: storeName,
      storeNameSecondary: storeNameSecondary,
      storeAddress: storeAddress,
      storePhone: storePhone,
      storeTaxId: storeTaxId,
      orderNumber: orderNumber,
      tableLabel: tableLabel,
      printedAt: printedAt,
      staffName: staffName,
      subtotal: subtotal,
      discount: discount,
      surcharge: surcharge,
      total: total,
      headerLines: headerLines,
      footerLines: footerLines,
      items: items,
      languages: languages,
      currency: currency,
      showOrderNumber: settings.showOrderNumber,
      showStaffName: settings.showStaffName,
      showDateTime: settings.showDateTime,
      showTable: settings.showTable,
      showSeatedTime: settings.showTimeSeated,
      seatedDuration: seatedDuration,
      showQrMarker: settings.showQrCode,
      guestLabel: guestLabel,
      taxNote: tax.$1,
      taxAmount: tax.$2,
      paymentRows: paymentRows,
      recipientName: _firstNonBlank(<String>[
        _value(payload, <String>['recipient_name_ja']),
        _value(snapshot, <String>['recipientNameJa', 'recipient_name_ja']),
      ]),
      purpose: _firstNonBlank(<String>[
        _value(payload, <String>['purpose_ja']),
        _value(snapshot, <String>['purposeJa', 'purpose_ja']),
      ]),
      isCopy: payload.containsKey('is_copy')
          ? _bool(payload['is_copy'])
          : _bool(snapshot['isCopy']),
    );
    if (isRyoushuusho) return _buildReceiptRyoushuusho(model);

    final template = _resolveReceiptTemplate(
      settings.receiptTemplate,
      printerSettings,
      receiptSettings,
    );
    return switch (template) {
      'classic' => _buildReceiptClassic(model),
      'compact' => _buildReceiptCompact(model),
      'detailed' => _buildReceiptDetailed(model),
      _ => _buildReceiptModern(model),
    };
  }

  static String kitchen(
    Map<String, dynamic> payload,
    StorePrintProfile? profile, {
    required int width,
    String fallbackOrderNumber = '',
  }) {
    final snapshot = _map(payload, <String>['snapshot']);
    final order = _order(payload, snapshot);
    final settings = profile?.templateSettings ?? TemplateSettings();
    final orderNumber = _firstNonBlank(<String>[
      _value(payload, <String>['order_number']),
      _value(order, <String>['order_no', 'order_number']),
      fallbackOrderNumber,
    ]);
    final table = _firstMap(<Map<String, dynamic>>[
      _map(payload, <String>['table']),
      _map(order, <String>['table']),
    ]);
    final tableLabel = settings.showTable
        ? _firstNonBlank(<String>[
            _value(payload, <String>[
              'table_label',
              'table_name',
              'table_number',
            ]),
            _value(table, <String>['name', 'code']),
            _value(order, <String>['table_number']),
          ])
        : '';
    final showDateTime = settings.showDateTime;
    final printedAt = showDateTime
        ? _firstNonBlank(<String>[
            _formatPrintDate(
              _value(payload, <String>['printed_at', 'created_at']),
            ),
            _formatPrintDate(
              _value(order, <String>['printed_at', 'paid_at', 'created_at']),
            ),
            _nowPrintTime(),
          ])
        : '';
    final isCancellation =
        _bool(payload['is_cancellation']) ||
        _bool(order['is_cancellation']) ||
        _value(payload, <String>['ticket_type', 'type']).toLowerCase() ==
            'cancellation';
    final isAdditional = _bool(payload['is_additional']);
    final ticketType = isCancellation ? 'HUY' : (isAdditional ? '追加' : '新規');
    final items = _items(payload, snapshot, order);
    final totalQuantity = _value(payload, <String>['total_quantity']);
    final guestCount = _numeric(payload['guest_count']);
    final model = _KitchenModel(
      width: width,
      orderNumber: orderNumber,
      tableLabel: tableLabel,
      guestCount: guestCount != null && guestCount > 0
          ? '${guestCount.toInt()}名'
          : '',
      ticketType: ticketType,
      stationName: _value(payload, <String>['station_name', 'station']),
      printedAt: printedAt,
      totalQuantity: totalQuantity,
      notes: isCancellation
          ? _value(payload, <String>['cancel_reason'])
          : _value(payload, <String>['note']),
      items: items,
      itemIds: _rawList(payload, 'item_ids'),
      showOrderNumber: settings.showOrderNumber,
      isCancellation: isCancellation,
    );
    final template = _resolveKitchenTemplate(settings.kitchenTemplate, payload);
    return switch (template) {
      'compact' => _buildKitchenCompact(model),
      'checklist' => _buildKitchenChecklist(model),
      _ => _buildKitchenStandard(model),
    };
  }

  static String _buildReceiptModern(_ReceiptModel model) {
    final lines = <String>[];
    _appendReceiptBrandHeader(lines, model);
    _appendReceiptMetaModern(lines, model);
    _appendRule(lines);
    _appendReceiptItemsModern(lines, model);
    _appendReceiptTotalsModern(lines, model);
    _appendReceiptPayments(lines, model);
    _appendReceiptTail(lines, model, centered: true);
    return lines.join('\n');
  }

  static String _buildReceiptClassic(_ReceiptModel model) {
    final lines = <String>[androidBigLineMarker + model.storeName];
    _appendReceiptStoreMeta(lines, model, centered: false);
    _appendRawLines(lines, model.headerLines, model.width);
    lines.add(_centerText('RECEIPT', model.width));
    _appendReceiptMetaBlock(lines, model, compact: false);
    _appendReceiptItemTable(lines, model, compact: false);
    _appendReceiptTotals(lines, model, strongTotal: false);
    _appendReceiptPayments(lines, model);
    _appendReceiptTail(lines, model, centered: false);
    return lines.join('\n');
  }

  static String _buildReceiptCompact(_ReceiptModel model) {
    final lines = <String>[
      androidBigLineMarker +
          _centerText(model.storeName, _bigLineWidth(model.width)).trim(),
    ];
    final meta = <String>[
      if (model.showOrderNumber && model.orderNumber.isNotEmpty)
        '#${model.orderNumber}',
      if (model.showTable && model.tableLabel.isNotEmpty) model.tableLabel,
      if (model.showDateTime && model.printedAt.isNotEmpty) model.printedAt,
    ].join('  ');
    lines.addAll(_wrapText(meta, model.width));
    _appendReceiptItemTable(lines, model, compact: true);
    _appendReceiptTotals(lines, model, strongTotal: true, compact: true);
    _appendReceiptPayments(lines, model);
    _appendReceiptTail(lines, model, centered: true, compact: true);
    return lines.join('\n');
  }

  static String _buildReceiptDetailed(_ReceiptModel model) {
    final lines = <String>[
      '$androidSansMarker$androidTitleMarker$androidCenterMarker${model.storeName}',
      if (model.storeNameSecondary.isNotEmpty)
        '$androidSansMarker$androidCenterMarker${model.storeNameSecondary}',
    ];
    _appendReceiptDetailedInfo(lines, model);
    _appendRule(lines);
    _appendReceiptDetailedItems(lines, model);
    _appendRule(lines);
    _appendReceiptDetailedTotals(lines, model);
    _appendReceiptPayments(lines, model);
    _appendReceiptTail(lines, model, centered: true);
    return lines.join('\n');
  }

  static String _buildReceiptRyoushuusho(_ReceiptModel model) {
    final lines = <String>[
      '$androidSansMarker$androidTitleMarker$androidCenterMarker領収書',
      if (model.isCopy)
        '$androidSansMarker$androidSmallMarker$androidCenterMarker（コピー）',
      '',
    ];
    final issuedAt = model.printedAt.isEmpty
        ? _nowPrintTime()
        : model.printedAt;
    if (issuedAt.isNotEmpty) lines.add('$androidMediumMarker発行日: $issuedAt');
    lines.add('');
    if (model.recipientName.isNotEmpty) {
      lines.addAll(
        _wrapText(
          '${model.recipientName} 様',
          model.width,
        ).map((line) => '$androidMediumMarker$line'),
      );
    } else {
      lines.add(
        '${_repeat('_', math.min(40, math.max(6, model.width - 3)))} 様',
      );
    }
    lines.add('');
    _appendRule(lines);
    lines.add(
      '$androidBigLineMarker$androidCenterMarker${model.total.isEmpty ? _formatMoney(0, model.currency) : model.total}',
    );
    _appendRule(lines);
    lines.add('');
    final purpose = model.purpose.isEmpty ? 'お品代として' : model.purpose;
    lines.addAll(
      _wrapText(
        '但し $purpose',
        model.width,
      ).map((line) => '$androidMediumMarker$line'),
    );
    lines.addAll(<String>['', '']);
    if (model.paymentRows.isNotEmpty) {
      lines.add('$androidMediumMarkerお支払: ${model.paymentRows.first.left}');
    }
    if (model.taxAmount.isNotEmpty) {
      lines.add('$androidSmallMarker${model.taxNote}');
      lines.addAll(
        _keyValueLines(
          '消費税',
          model.taxAmount,
          model.width,
        ).map((line) => '$androidSmallMarker$line'),
      );
    }
    _appendRule(lines);
    lines.add('');
    if (model.storeName.isNotEmpty &&
        model.storeName.toUpperCase() != 'HYBRID POS') {
      lines.addAll(
        _wrapText(model.storeName, model.width).map(
          (line) =>
              '$androidSansMarker$androidMediumMarker$androidCenterMarker$line',
        ),
      );
    }
    if (model.storeAddress.isNotEmpty) {
      lines.addAll(
        _wrapText(model.storeAddress, model.width).map(
          (line) =>
              '$androidSansMarker$androidSmallMarker$androidCenterMarker$line',
        ),
      );
    }
    if (model.storePhone.isNotEmpty) {
      lines.add(
        '$androidSansMarker$androidSmallMarker${androidCenterMarker}TEL: ${model.storePhone}',
      );
    }
    if (model.storeTaxId.isNotEmpty) {
      lines.add(
        '$androidSansMarker$androidSmallMarker${androidCenterMarker}登録番号: ${model.storeTaxId}',
      );
    }
    return lines.join('\n');
  }

  static void _appendReceiptBrandHeader(
    List<String> lines,
    _ReceiptModel model,
  ) {
    lines.add(
      '$androidSansMarker$androidTitleMarker$androidCenterMarker${model.storeName}',
    );
    final storeLines = <String>[
      if (model.storeNameSecondary.isNotEmpty) model.storeNameSecondary,
      if (model.storeAddress.isNotEmpty) model.storeAddress,
      if (model.storePhone.isNotEmpty) 'TEL: ${model.storePhone}',
      if (model.storeTaxId.isNotEmpty) model.storeTaxId,
    ];
    for (final line in storeLines) {
      lines.addAll(
        _wrapText(line, model.width).map(
          (value) =>
              '$androidSansMarker$androidSmallMarker$androidCenterMarker$value',
        ),
      );
    }
    for (final line in model.headerLines) {
      lines.addAll(
        _wrapText(
          line,
          model.width,
        ).map((value) => '$androidSansMarker$androidCenterMarker$value'),
      );
    }
    lines.add('');
  }

  static void _appendReceiptStoreMeta(
    List<String> lines,
    _ReceiptModel model, {
    required bool centered,
  }) {
    final storeLines = <String>[
      if (model.storeNameSecondary.isNotEmpty) model.storeNameSecondary,
      if (model.storeAddress.isNotEmpty) model.storeAddress,
      if (model.storePhone.isNotEmpty) 'TEL: ${model.storePhone}',
      if (model.storeTaxId.isNotEmpty) model.storeTaxId,
    ];
    for (final line in storeLines) {
      for (final wrapped in _wrapText(line, model.width)) {
        lines.add(centered ? _centerText(wrapped, model.width) : wrapped);
      }
    }
  }

  static void _appendRawLines(
    List<String> lines,
    List<String> values,
    int width,
  ) {
    for (final value in values) {
      lines.addAll(_wrapText(value, width));
    }
  }

  static void _appendReceiptMetaBlock(
    List<String> lines,
    _ReceiptModel model, {
    required bool compact,
  }) {
    final rows = <_Pair>[
      if (model.showOrderNumber && model.orderNumber.isNotEmpty)
        _Pair(_receiptLabel('order', model.languages), '#${model.orderNumber}'),
      if (model.showTable && model.tableLabel.isNotEmpty)
        _Pair(_receiptLabel('table', model.languages), model.tableLabel),
      if (model.showDateTime && model.printedAt.isNotEmpty)
        _Pair(_receiptLabel('date', model.languages), model.printedAt),
      if (model.showStaffName && model.staffName.isNotEmpty)
        _Pair(_receiptLabel('staff', model.languages), model.staffName),
      if (model.showSeatedTime && model.seatedDuration.isNotEmpty)
        _Pair(_receiptLabel('time', model.languages), model.seatedDuration),
    ];
    if (rows.isEmpty) return;
    if (compact) {
      lines.addAll(
        _wrapText(
          rows.map((row) => '${row.left}: ${row.right}').join('  '),
          model.width,
        ),
      );
      return;
    }
    for (final row in rows) {
      lines.addAll(_keyValueLines(row.left, row.right, model.width));
    }
  }

  static void _appendReceiptMetaModern(
    List<String> lines,
    _ReceiptModel model,
  ) {
    final order = model.showOrderNumber && model.orderNumber.isNotEmpty
        ? '#${model.orderNumber}'
        : '';
    final table = model.showTable && model.tableLabel.isNotEmpty
        ? model.tableLabel
        : '';
    final date = model.showDateTime && model.printedAt.isNotEmpty
        ? model.printedAt
        : '';
    final staff = model.showStaffName && model.staffName.isNotEmpty
        ? model.staffName
        : '';
    final seated = model.showSeatedTime && model.seatedDuration.isNotEmpty
        ? model.seatedDuration
        : '';
    _appendMetaPair(lines, model.width, order, table);
    _appendMetaPair(
      lines,
      model.width,
      date,
      staff.isNotEmpty ? staff : seated,
    );
  }

  static void _appendMetaPair(
    List<String> lines,
    int width,
    String left,
    String right,
  ) {
    if (left.isNotEmpty && right.isNotEmpty) {
      lines.addAll(_keyValueLines(left, right, width));
    } else if (left.isNotEmpty) {
      lines.addAll(_wrapText(left, width));
    } else if (right.isNotEmpty) {
      lines.addAll(_wrapText(right, width));
    }
  }

  static void _appendReceiptItemsModern(
    List<String> lines,
    _ReceiptModel model,
  ) {
    if (model.items.isEmpty) {
      lines.add(
        _centerText(_receiptLabel('unknownItem', model.languages), model.width),
      );
      return;
    }
    for (final item in model.items) {
      final name = _receiptItemName(item, model.languages);
      final quantityValue = _numeric(item['quantity']) ?? 1;
      final quantity = _formatQuantity(quantityValue);
      final unitPrice = _receiptItemUnitPrice(item, model.currency);
      final amount = _receiptItemAmount(item, quantityValue, model.currency);
      for (final line in _wrapText(name, model.width)) {
        lines.add('$androidSansMarker$line');
      }
      final detail = unitPrice.isNotEmpty
          ? '$quantity x $unitPrice'
          : '${_receiptLabel('qty', model.languages)}: $quantity';
      lines.addAll(_keyValueLines('   $detail', amount, model.width));
    }
  }

  static void _appendReceiptTotalsModern(
    List<String> lines,
    _ReceiptModel model,
  ) {
    final hasAdjustment =
        _shouldRenderAmount(model.discount) ||
        _shouldRenderAmount(model.surcharge);
    if (model.total.isEmpty && !hasAdjustment && model.subtotal.isEmpty) return;
    _appendRule(lines);
    if (hasAdjustment) {
      if (model.subtotal.isNotEmpty) {
        lines.addAll(
          _keyValueLines(
            _receiptLabel('subtotal', model.languages),
            model.subtotal,
            model.width,
          ),
        );
      }
      if (_shouldRenderAmount(model.discount)) {
        lines.addAll(
          _keyValueLines(
            _receiptLabel('discount', model.languages),
            model.discount,
            model.width,
          ),
        );
      }
      if (_shouldRenderAmount(model.surcharge)) {
        lines.addAll(
          _keyValueLines(
            _receiptLabel('surcharge', model.languages),
            model.surcharge,
            model.width,
          ),
        );
      }
    }
    final total = model.total.isEmpty ? model.subtotal : model.total;
    if (total.isNotEmpty) {
      final totalLines = _keyValueLines(
        _receiptLabel('total', model.languages),
        total,
        _bigLineWidth(model.width),
      );
      lines.addAll(
        totalLines.map(
          (line) => '$androidBigLineMarker$androidInvertMarker $line ',
        ),
      );
    }
  }

  static void _appendReceiptItemTable(
    List<String> lines,
    _ReceiptModel model, {
    required bool compact,
  }) {
    if (model.items.isEmpty) {
      lines.add(
        _centerText(_receiptLabel('unknownItem', model.languages), model.width),
      );
      return;
    }
    if (!compact) {
      lines.addAll(
        _keyValueLines(
          _receiptLabel('item', model.languages),
          _receiptLabel('amount', model.languages),
          model.width,
        ),
      );
    }
    for (var index = 0; index < model.items.length; index++) {
      final item = model.items[index];
      final name = _receiptItemName(item, model.languages);
      final quantityValue = _numeric(item['quantity']) ?? 1;
      final quantity = _formatQuantity(quantityValue);
      final unitPrice = _receiptItemUnitPrice(item, model.currency);
      final amount = _receiptItemAmount(item, quantityValue, model.currency);
      if (compact) {
        lines.addAll(_keyValueLines('$quantity x $name', amount, model.width));
      } else {
        lines.addAll(_keyValueLines(name, amount, model.width));
        final detail = unitPrice.isNotEmpty
            ? '$quantity x $unitPrice'
            : '${_receiptLabel('qty', model.languages)}: $quantity';
        lines.addAll(_wrapText('  $detail', model.width));
      }
      _appendReceiptItemOptions(lines, item, model);
      _appendItemNotes(lines, item, model);
      if (!compact && index < model.items.length - 1) lines.add('');
    }
  }

  static void _appendReceiptDetailedInfo(
    List<String> lines,
    _ReceiptModel model,
  ) {
    final ja = model.languages.contains('ja');
    String label(String jp, String vi) => ja ? jp : vi;
    final storeLines = <String>[
      if (model.storeAddress.isNotEmpty) model.storeAddress,
      if (model.storePhone.isNotEmpty)
        '${label('TEL', 'ĐT')}: ${model.storePhone}',
      if (model.storeTaxId.isNotEmpty)
        '${label('登録番号', 'MST')}: ${model.storeTaxId}',
    ];
    for (final line in storeLines) {
      lines.addAll(
        _wrapText(
          line,
          model.width,
        ).map((value) => '$androidSansMarker$androidCenterMarker$value'),
      );
    }
    _appendShortRule(lines);
    if (model.showOrderNumber && model.orderNumber.isNotEmpty) {
      final right = model.guestLabel.isNotEmpty
          ? '  ${label('人数', 'Số khách')}: ${model.guestLabel}'
          : '';
      lines.addAll(_wrapText('No. ${model.orderNumber}$right', model.width));
    }
    final staffTable = <String>[
      if (model.showStaffName && model.staffName.isNotEmpty)
        '${label('担当', 'NV')}: ${model.staffName}',
      if (model.showTable && model.tableLabel.isNotEmpty)
        '${label('テーブル', 'Bàn')}: ${model.tableLabel}',
    ];
    if (staffTable.isNotEmpty) {
      lines.addAll(_wrapText(staffTable.join('  '), model.width));
    }
    if (model.showDateTime && model.printedAt.isNotEmpty) {
      lines.add(model.printedAt);
    }
  }

  static void _appendReceiptDetailedItems(
    List<String> lines,
    _ReceiptModel model,
  ) {
    if (model.items.isEmpty) {
      lines.add(
        _centerText(_receiptLabel('unknownItem', model.languages), model.width),
      );
      return;
    }
    lines.addAll(
      _keyValueLines(
        _receiptLabel('item', model.languages),
        _receiptLabel('amount', model.languages),
        model.width,
      ),
    );
    for (final item in model.items) {
      final name = _receiptItemName(item, model.languages);
      final quantityValue = _numeric(item['quantity']) ?? 1;
      final quantity = _formatQuantity(quantityValue);
      final unitPrice = _receiptItemUnitPrice(item, model.currency);
      final amount = _receiptItemAmount(item, quantityValue, model.currency);
      lines.addAll(_keyValueLines(name, amount, model.width));
      final detail = unitPrice.isNotEmpty
          ? '$quantity x $unitPrice'
          : '${_receiptLabel('qty', model.languages)}: $quantity';
      lines.addAll(_wrapText('    $detail', model.width));
      _appendReceiptItemOptions(lines, item, model, indent: '    ');
      _appendItemNotes(lines, item, model, indent: '    ');
    }
  }

  static void _appendReceiptItemOptions(
    List<String> lines,
    Map<String, dynamic> item,
    _ReceiptModel model, {
    String indent = '  ',
  }) {
    final options = _list(item, 'selected_options');
    for (final option in options) {
      final name = _firstNonBlank(<String>[
        _value(option, <String>['option_name']),
        _value(option, <String>['label']),
        _value(option, <String>['name']),
      ]);
      if (name.isEmpty) continue;
      final quantity = (_numeric(option['quantity']) ?? 1).toInt();
      final prefix = quantity > 1 ? '$indent+ ${quantity}x ' : '$indent+ ';
      lines.addAll(_wrapText('$prefix$name', model.width));
    }
  }

  static void _appendItemNotes(
    List<String> lines,
    Map<String, dynamic> item,
    _ReceiptModel model, {
    String indent = '  ',
  }) {
    final note = _clean(_value(item, <String>['note']));
    if (note.isNotEmpty) {
      lines.addAll(
        _wrapText(
          '$indent${_receiptLabel('note', model.languages)}: $note',
          model.width,
        ),
      );
    }
    for (final raw in _rawList(item, 'notes')) {
      final value = _clean(raw.toString());
      if (value.isNotEmpty) {
        lines.addAll(
          _wrapText(
            '$indent${_receiptLabel('note', model.languages)}: $value',
            model.width,
          ),
        );
      }
    }
  }

  static void _appendReceiptDetailedTotals(
    List<String> lines,
    _ReceiptModel model,
  ) {
    final ja = model.languages.contains('ja');
    String label(String jp, String vi) => ja ? jp : vi;
    if (model.subtotal.isNotEmpty) {
      lines.addAll(
        _keyValueLines(label('小計', 'Tạm tính'), model.subtotal, model.width),
      );
    }
    if (model.taxAmount.isNotEmpty) {
      if (model.taxNote.isNotEmpty) lines.add(model.taxNote);
      lines.addAll(
        _keyValueLines(
          label('消費税(10%)', 'Thuế (10%)'),
          model.taxAmount,
          model.width,
        ),
      );
    }
    if (_shouldRenderAmount(model.discount)) {
      lines.addAll(
        _keyValueLines(label('割引', 'Giảm giá'), model.discount, model.width),
      );
    }
    if (_shouldRenderAmount(model.surcharge)) {
      lines.addAll(
        _keyValueLines(label('加算', 'Phụ thu'), model.surcharge, model.width),
      );
    }
    final total = model.total.isEmpty ? model.subtotal : model.total;
    if (total.isNotEmpty) {
      _appendRule(lines);
      lines.addAll(
        _keyValueLines(
          label('合計', 'Tổng cộng'),
          total,
          _bigLineWidth(model.width),
        ).map((line) => '$androidBigLineMarker$line'),
      );
    }
  }

  static void _appendReceiptTotals(
    List<String> lines,
    _ReceiptModel model, {
    required bool strongTotal,
    bool compact = false,
  }) {
    if (model.subtotal.isEmpty &&
        model.discount.isEmpty &&
        model.surcharge.isEmpty &&
        model.total.isEmpty)
      return;
    if (!compact && model.subtotal.isNotEmpty) {
      lines.addAll(
        _keyValueLines(
          _receiptLabel('subtotal', model.languages),
          model.subtotal,
          model.width,
        ),
      );
    }
    if (_shouldRenderAmount(model.discount)) {
      lines.addAll(
        _keyValueLines(
          _receiptLabel('discount', model.languages),
          model.discount,
          model.width,
        ),
      );
    }
    if (_shouldRenderAmount(model.surcharge)) {
      lines.addAll(
        _keyValueLines(
          _receiptLabel('surcharge', model.languages),
          model.surcharge,
          model.width,
        ),
      );
    }
    if (model.total.isNotEmpty) {
      final totalWidth = strongTotal ? _bigLineWidth(model.width) : model.width;
      final values = _keyValueLines(
        _receiptLabel('total', model.languages),
        model.total,
        totalWidth,
      );
      lines.addAll(
        values.map((line) => strongTotal ? '$androidBigLineMarker$line' : line),
      );
    }
  }

  static void _appendReceiptPayments(List<String> lines, _ReceiptModel model) {
    if (model.paymentRows.isEmpty) return;
    lines.add('');
    for (final row in model.paymentRows) {
      lines.addAll(_keyValueLines(row.left, row.right, model.width));
    }
  }

  static void _appendReceiptTail(
    List<String> lines,
    _ReceiptModel model, {
    required bool centered,
    bool compact = false,
  }) {
    if (model.footerLines.isEmpty && !model.showQrMarker) return;
    if (!compact) lines.add('');
    if (model.showQrMarker) {
      final value = '[ ${_receiptLabel('qrCode', model.languages)} ]';
      lines.add(
        centered ? '$androidSansMarker$androidCenterMarker$value' : value,
      );
    }
    for (final line in model.footerLines) {
      for (final wrapped in _wrapText(line, model.width)) {
        lines.add(
          centered
              ? '$androidSansMarker$androidSmallMarker$androidCenterMarker$wrapped'
              : wrapped,
        );
      }
    }
  }

  static String _buildKitchenStandard(_KitchenModel model) {
    final lines = <String>[];
    _appendKitchenCompactHeader(lines, model);
    _appendKitchenItems(lines, model, model.isCancellation ? 'HUY ' : '');
    _appendKitchenOrderNote(lines, model);
    return lines.join('\n');
  }

  static String _buildKitchenCompact(_KitchenModel model) {
    final lines = <String>[
      '$androidBigLineMarker${model.tableLabel.isEmpty ? '-' : model.tableLabel}  ${model.ticketType}',
    ];
    _appendKitchenFooterMeta(lines, model);
    _appendRule(lines);
    _appendKitchenItems(lines, model, model.isCancellation ? 'HUY ' : '');
    _appendKitchenNotesAndFooter(lines, model, compact: true);
    return lines.join('\n');
  }

  static String _buildKitchenChecklist(_KitchenModel model) {
    final lines = <String>[];
    _appendKitchenHeader(
      lines,
      model,
      model.isCancellation ? 'CANCEL' : 'CHECKLIST',
    );
    _appendKitchenItems(
      lines,
      model,
      model.isCancellation ? '[X] HUY ' : '[ ] ',
    );
    _appendKitchenNotesAndFooter(lines, model);
    return lines.join('\n');
  }

  static void _appendKitchenCompactHeader(
    List<String> lines,
    _KitchenModel model,
  ) {
    final table = model.tableLabel.isEmpty ? '-' : model.tableLabel;
    final left = model.isCancellation ? 'HUY $table' : table;
    final right = model.ticketType;
    final headline =
        _columnWidth(left) + _columnWidth(right) + 1 <=
            _bigLineWidth(model.width)
        ? _padEndToColumns(
                left,
                _bigLineWidth(model.width) - _columnWidth(right),
              ) +
              right
        : <String>[left, right].where((value) => value.isNotEmpty).join('  ');
    lines.add('$androidBigLineMarker$headline');
    final meta = <String>[
      if (model.showOrderNumber && model.orderNumber.isNotEmpty)
        '#${_shortOrderNo(model.orderNumber)}',
      if (model.printedAt.isNotEmpty) model.printedAt,
      if (model.guestCount.isNotEmpty) model.guestCount,
      if (model.totalQuantity.isNotEmpty) '${model.totalQuantity} món',
      if (model.stationName.isNotEmpty) model.stationName,
    ].join('  ·  ');
    if (meta.isNotEmpty) lines.addAll(_wrapText(meta, model.width));
    _appendRule(lines);
  }

  static void _appendKitchenHeader(
    List<String> lines,
    _KitchenModel model,
    String label,
  ) {
    final table = model.tableLabel.isEmpty ? '-' : model.tableLabel;
    final prefix = model.isCancellation ? 'HUY BAN' : 'BAN';
    lines.add('$androidBigLineMarker$prefix $table  ${model.ticketType}');
    lines.add(_centerText(label, model.width));
    _appendKitchenFooterMeta(lines, model);
    _appendRule(lines);
  }

  static void _appendKitchenFooterMeta(
    List<String> lines,
    _KitchenModel model,
  ) {
    final rows = <_Pair>[
      if (model.showOrderNumber && model.orderNumber.isNotEmpty)
        _Pair('Order', '#${_shortOrderNo(model.orderNumber)}'),
      if (model.stationName.isNotEmpty) _Pair('Station', model.stationName),
      if (model.printedAt.isNotEmpty) _Pair('Time', model.printedAt),
      if (model.guestCount.isNotEmpty) _Pair('Guests', model.guestCount),
      if (model.totalQuantity.isNotEmpty) _Pair('Qty', model.totalQuantity),
    ];
    for (final row in rows) {
      lines.addAll(_keyValueLines(row.left, row.right, model.width));
    }
  }

  static void _appendKitchenItems(
    List<String> lines,
    _KitchenModel model,
    String bulletPrefix,
  ) {
    if (model.items.isEmpty) {
      lines.add('商品数: ${model.itemIds.length}');
      lines.addAll(model.itemIds.map((value) => '$bulletPrefix$value'));
      return;
    }
    for (var index = 0; index < model.items.length; index++) {
      final item = model.items[index];
      final name = _firstNonBlank(<String>[
        _value(item, <String>['name_ja']),
        _value(item, <String>['product_name_ja']),
        _value(item, <String>['name']),
        _value(item, <String>['product_name']),
        _value(item, <String>['name_snapshot']),
        '商品',
      ]);
      final quantity = _formatQuantity(_numeric(item['quantity']) ?? 1);
      if (index > 0) lines.add('');
      final itemLines = _wrapText('$bulletPrefix$quantity  $name', model.width);
      for (var lineIndex = 0; lineIndex < itemLines.length; lineIndex++) {
        lines.add(
          lineIndex == 0
              ? '$androidBigLineMarker${itemLines[lineIndex]}'
              : itemLines[lineIndex],
        );
      }
      for (final option in _list(item, 'selected_options')) {
        final optionName = _firstNonBlank(<String>[
          _value(option, <String>['option_name']),
          _value(option, <String>['label']),
        ]);
        if (optionName.isEmpty) continue;
        final optionQuantity = (_numeric(option['quantity']) ?? 1).toInt();
        final prefix = optionQuantity > 1
            ? '   + ${optionQuantity}x '
            : '   + ';
        lines.addAll(_wrapText('$prefix$optionName', model.width));
      }
      final note = _clean(_value(item, <String>['note']));
      if (note.isNotEmpty)
        lines.addAll(_wrapText('   NOTE: $note', model.width));
      for (final raw in _rawList(item, 'notes')) {
        final value = _clean(raw.toString());
        if (value.isNotEmpty)
          lines.addAll(_wrapText('   NOTE: $value', model.width));
      }
    }
  }

  static void _appendKitchenOrderNote(List<String> lines, _KitchenModel model) {
    final note = _clean(model.notes);
    if (note.isEmpty) return;
    lines.addAll(_wrapText('! $note', model.width));
  }

  static void _appendKitchenNotesAndFooter(
    List<String> lines,
    _KitchenModel model, {
    bool compact = false,
  }) {
    final note = _clean(model.notes);
    if (note.isNotEmpty) lines.addAll(_wrapText('NOTE: $note', model.width));
    final footer = <String>[
      if (model.printedAt.isNotEmpty) model.printedAt,
      if (model.showOrderNumber && model.orderNumber.isNotEmpty)
        '#${model.orderNumber}',
    ].join('  ');
    if (footer.isNotEmpty) lines.add(_centerText(footer, model.width));
  }

  static void _appendRule(List<String> lines) => lines.add(androidRuleMarker);

  static void _appendShortRule(List<String> lines) =>
      lines.add('$androidRuleMarker$androidCenterMarker');
}

class _ReceiptModel {
  const _ReceiptModel({
    required this.width,
    required this.storeName,
    required this.storeNameSecondary,
    required this.storeAddress,
    required this.storePhone,
    required this.storeTaxId,
    required this.orderNumber,
    required this.tableLabel,
    required this.printedAt,
    required this.staffName,
    required this.subtotal,
    required this.discount,
    required this.surcharge,
    required this.total,
    required this.headerLines,
    required this.footerLines,
    required this.items,
    required this.languages,
    required this.currency,
    required this.showOrderNumber,
    required this.showStaffName,
    required this.showDateTime,
    required this.showTable,
    required this.showSeatedTime,
    required this.seatedDuration,
    required this.showQrMarker,
    required this.guestLabel,
    required this.taxNote,
    required this.taxAmount,
    required this.paymentRows,
    required this.recipientName,
    required this.purpose,
    required this.isCopy,
  });

  final int width;
  final String storeName;
  final String storeNameSecondary;
  final String storeAddress;
  final String storePhone;
  final String storeTaxId;
  final String orderNumber;
  final String tableLabel;
  final String printedAt;
  final String staffName;
  final String subtotal;
  final String discount;
  final String surcharge;
  final String total;
  final List<String> headerLines;
  final List<String> footerLines;
  final List<Map<String, dynamic>> items;
  final List<String> languages;
  final String currency;
  final bool showOrderNumber;
  final bool showStaffName;
  final bool showDateTime;
  final bool showTable;
  final bool showSeatedTime;
  final String seatedDuration;
  final bool showQrMarker;
  final String guestLabel;
  final String taxNote;
  final String taxAmount;
  final List<_Pair> paymentRows;
  final String recipientName;
  final String purpose;
  final bool isCopy;
}

class _KitchenModel {
  const _KitchenModel({
    required this.width,
    required this.orderNumber,
    required this.tableLabel,
    required this.guestCount,
    required this.ticketType,
    required this.stationName,
    required this.printedAt,
    required this.totalQuantity,
    required this.notes,
    required this.items,
    required this.itemIds,
    required this.showOrderNumber,
    required this.isCancellation,
  });

  final int width;
  final String orderNumber;
  final String tableLabel;
  final String guestCount;
  final String ticketType;
  final String stationName;
  final String printedAt;
  final String totalQuantity;
  final String notes;
  final List<Map<String, dynamic>> items;
  final List<Object?> itemIds;
  final bool showOrderNumber;
  final bool isCancellation;
}

class _Pair {
  const _Pair(this.left, this.right);

  final String left;
  final String right;
}

Map<String, dynamic> _map(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is Map) return Map<String, dynamic>.from(value);
  }
  return <String, dynamic>{};
}

Map<String, dynamic> _firstMap(Iterable<Map<String, dynamic>> values) {
  for (final value in values) {
    if (value.isNotEmpty) return value;
  }
  return <String, dynamic>{};
}

Map<String, dynamic> _order(
  Map<String, dynamic> payload,
  Map<String, dynamic> snapshot,
) {
  final nestedSnapshot = _map(snapshot, <String>['order']);
  if (nestedSnapshot.isNotEmpty) return nestedSnapshot;
  final nestedPayload = _map(payload, <String>['order']);
  if (nestedPayload.isNotEmpty) return nestedPayload;
  return snapshot.isEmpty ? payload : snapshot;
}

List<Map<String, dynamic>> _items(
  Map<String, dynamic> payload,
  Map<String, dynamic> snapshot,
  Map<String, dynamic> order,
) {
  for (final source in <Map<String, dynamic>>[snapshot, payload, order]) {
    for (final key in <String>['items', 'order_items']) {
      final result = _list(source, key);
      if (result.isNotEmpty) return result;
    }
  }
  return <Map<String, dynamic>>[];
}

List<Map<String, dynamic>> _list(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) return <Map<String, dynamic>>[];
  return value
      .whereType<Map<Object?, Object?>>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

List<Object?> _rawList(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is List ? List<Object?>.from(value) : <Object?>[];
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

String _firstNonBlank(Iterable<String> values) {
  for (final value in values) {
    final text = value.trim();
    if (text.isNotEmpty && text.toLowerCase() != 'null') return text;
  }
  return '';
}

String _clean(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

String _localOrPayload(
  String? local,
  Map<String, dynamic> remote,
  List<String> keys,
  String fallback,
) {
  final localValue = local?.trim() ?? '';
  final remoteValue = _value(remote, keys);
  if (localValue.isNotEmpty &&
      (remoteValue.isEmpty ||
          (localValue != fallback &&
              localValue != 'AIRPOS' &&
              localValue != 'HYBRID POS'))) {
    return localValue;
  }
  return remoteValue.isNotEmpty ? remoteValue : fallback;
}

List<String> _languages(Object? value) {
  final values = value is List
      ? value.map((item) => item.toString())
      : value is String
      ? value.split(RegExp(r'[,/]'))
      : const <String>[];
  final result = <String>[];
  for (final raw in values) {
    final language = switch (raw.trim().toLowerCase()) {
      'vi' || 'vn' || 'vietnamese' => 'vi',
      'ja' || 'jp' || 'japanese' => 'ja',
      'zh' || 'cn' || 'chinese' => 'zh',
      'ko' || 'kr' || 'korean' => 'ko',
      'id' || 'indonesian' => 'id',
      'my' || 'mm' || 'burmese' => 'my',
      'en' || 'english' => 'en',
      _ => '',
    };
    if (language.isNotEmpty && !result.contains(language)) result.add(language);
  }
  return result;
}

List<String> _localizedProfileLines(
  String vi,
  String ja,
  List<String> languages,
) {
  final lines = <String>[];
  if (languages.contains('vi') && vi.trim().isNotEmpty) lines.add(vi.trim());
  if (languages.contains('ja') && ja.trim().isNotEmpty) lines.add(ja.trim());
  if (lines.isEmpty) {
    if (vi.trim().isNotEmpty) lines.add(vi.trim());
    if (ja.trim().isNotEmpty && !lines.contains(ja.trim()))
      lines.add(ja.trim());
  }
  return lines;
}

List<String> _localizedPayloadLines(
  Map<String, dynamic> settings,
  String baseKey,
  List<String> languages,
) {
  final translated = _map(settings, <String>['${baseKey}_translations']);
  final vi = _firstNonBlank(<String>[
    _value(settings, <String>['${baseKey}_vi']),
    _value(translated, <String>['vi']),
    _value(settings, <String>[baseKey]),
  ]);
  final ja = _firstNonBlank(<String>[
    _value(settings, <String>['${baseKey}_ja']),
    _value(translated, <String>['ja']),
  ]);
  return _localizedProfileLines(vi, ja, languages);
}

bool _isGenericReceiptHeaderLine(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized == 'receipt' ||
      normalized == '*** receipt ***' ||
      normalized == 'detailed receipt';
}

bool _bool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return switch (value?.toString().trim().toLowerCase()) {
    'true' || '1' || 'yes' || 'y' => true,
    _ => false,
  };
}

num? _numeric(Object? value) {
  if (value is num) return value;
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  return num.tryParse(
    text.replaceAll(',', '').replaceAll(RegExp(r'[^0-9.+-]'), ''),
  );
}

String _valueAsMoney(Object? value, String currency) {
  final numeric = _numeric(value);
  if (numeric == null) return '';
  return _formatMoney(numeric, currency);
}

String _formatMoney(num value, String currency) {
  final code = currency.trim().toUpperCase().isEmpty
      ? 'JPY'
      : currency.trim().toUpperCase();
  if (code == 'JPY') return '¥${_formatNumber(value, 0)}';
  if (code == 'VND') return '${_formatNumber(value, 0)}₫';
  return '${_formatNumber(value, 2)} $code';
}

String _formatNumber(num value, int decimals) {
  final fixed = value.toDouble().toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final negative = parts.first.startsWith('-');
  final digits = negative ? parts.first.substring(1) : parts.first;
  final groups = <String>[];
  for (var end = digits.length; end > 0; end -= 3) {
    final start = math.max(0, end - 3);
    groups.insert(0, digits.substring(start, end));
  }
  final result = groups.join(',');
  return '${negative ? '-' : ''}$result${decimals == 0 ? '' : '.${parts[1]}'}';
}

String _formatQuantity(num value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

bool _shouldRenderAmount(String value) {
  final normalized = value.trim();
  return normalized.isNotEmpty &&
      !<String>{'0', '0.0', '0.00'}.contains(normalized);
}

int? _durationMinutes(Object? value) {
  final numeric = _numeric(value);
  if (numeric == null || numeric <= 0) return null;
  return numeric.round();
}

String _formatReceiptDuration(int minutes, List<String> languages) {
  final hours = minutes ~/ 60;
  final remaining = minutes % 60;
  return switch (languages.firstOrNull) {
    'ja' => hours > 0 ? '${hours}時間${remaining}分' : '${remaining}分',
    'en' => hours > 0 ? '${hours}h ${remaining}m' : '${remaining}m',
    _ => hours > 0 ? '$hours giờ $remaining phút' : '$remaining phút',
  };
}

String _formatPrintDate(String value) {
  final text = value.trim();
  if (text.isEmpty) return '';
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return text;
  final hasZone =
      text.contains('T') &&
      (text.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(text));
  final local = hasZone ? parsed.toUtc().add(const Duration(hours: 9)) : parsed;
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}/${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

String _nowPrintTime() {
  final now = DateTime.now().toUtc().add(const Duration(hours: 9));
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}/${two(now.month)}/${two(now.day)} ${two(now.hour)}:${two(now.minute)}';
}

(String, String) _computeInclusiveTax(
  num total,
  String currency,
  List<String> languages,
) {
  if (currency.trim().toUpperCase() != 'JPY' || total <= 0) return ('', '');
  final gross = total.round();
  final tax = gross - (gross / 1.10).round();
  if (tax <= 0) return ('', '');
  final note = languages.contains('ja')
      ? '※ 10%対象 (${_formatMoney(gross, currency)})'
      : '※ 10% (${_formatMoney(gross, currency)})';
  return (note, _formatMoney(tax, currency));
}

List<_Pair> _paymentRows(
  Map<String, dynamic> payload,
  String currency,
  List<String> languages,
) {
  final snapshot = _map(payload, <String>['receipt_snapshot', 'snapshot']);
  final order = _order(payload, snapshot);
  List<Map<String, dynamic>> payments = <Map<String, dynamic>>[];
  for (final source in <Map<String, dynamic>>[payload, snapshot, order]) {
    payments = _list(source, 'payments');
    if (payments.isNotEmpty) break;
  }
  final rows = <_Pair>[];
  for (final payment in payments) {
    final status = _value(payment, <String>['status', 'state']).toLowerCase();
    if (status.isNotEmpty && status != 'completed') continue;
    final method = _paymentLabel(
      _value(payment, <String>['method', 'payment_method', 'type']),
      languages,
    );
    final amountValue = _numeric(payment['amount'] ?? payment['paid_amount']);
    if (amountValue != null)
      rows.add(_Pair(method, _formatMoney(amountValue, currency)));
  }
  final snapshotPayments = _list(snapshot, 'payments');
  Object? firstPaymentField(List<String> keys) {
    for (final payment in <Map<String, dynamic>>[
      ...snapshotPayments,
      ...payments,
    ]) {
      for (final key in keys) {
        final value = payment[key];
        if (_numeric(value) != null) return value;
      }
    }
    return null;
  }

  Object? firstNumericValue(Iterable<Object?> values) {
    for (final value in values) {
      if (_numeric(value) != null) return value;
    }
    return null;
  }

  final tendered = _numeric(
    firstNumericValue(<Object?>[
      payload['amount_tendered'],
      payload['tendered'],
      payload['cash_received'],
      firstPaymentField(<String>[
        'received_amount',
        'amount_tendered',
        'tendered',
        'cash_received',
      ]),
    ]),
  );
  final change = _numeric(
    firstNumericValue(<Object?>[
      payload['change'],
      payload['change_amount'],
      firstPaymentField(<String>['change_amount', 'change']),
    ]),
  );
  if (tendered != null && tendered > 0) {
    rows.add(
      _Pair(
        languages.contains('ja') ? 'お預り' : 'Tiền nhận',
        _formatMoney(tendered, currency),
      ),
    );
  }
  if (change != null && change >= 0) {
    rows.add(
      _Pair(
        languages.contains('ja') ? 'お釣' : 'Tiền thối',
        _formatMoney(change, currency),
      ),
    );
  }
  return rows;
}

String _paymentLabel(String value, List<String> languages) {
  final key = value
      .trim()
      .toLowerCase()
      .replaceAll('-', '_')
      .replaceAll(' ', '_');
  final ja = languages.contains('ja');
  final vi = languages.contains('vi');
  return switch (key) {
    'cash' || '現金' => _bilingualLabel('現金', 'Tiền mặt', 'Cash', ja, vi),
    'card' ||
    'credit_card' ||
    'クレジットカード' => _bilingualLabel('カード', 'Thẻ', 'Card', ja, vi),
    'transfer' ||
    'bank_transfer' ||
    '振込' => _bilingualLabel('振込', 'Chuyển khoản', 'Transfer', ja, vi),
    'voucher' || '商品券' => _bilingualLabel('クーポン', 'Voucher', 'Voucher', ja, vi),
    _ =>
      value.trim().isEmpty ? _receiptLabel('payment', languages) : value.trim(),
  };
}

String _bilingualLabel(
  String jaLabel,
  String viLabel,
  String enLabel,
  bool ja,
  bool vi,
) {
  if (ja && vi) return '$jaLabel ($viLabel)';
  if (ja) return jaLabel;
  if (vi) return viLabel;
  return enLabel;
}

String _resolveReceiptTemplate(
  String local,
  Map<String, dynamic> printerSettings,
  Map<String, dynamic> receiptSettings,
) {
  final candidates = <String>[
    local,
    _value(printerSettings, <String>['receipt_template', 'template']),
    _value(receiptSettings, <String>['receipt_template', 'template']),
  ];
  for (final raw in candidates) {
    switch (raw.trim().toLowerCase()) {
      case 'classic':
        return 'classic';
      case 'compact':
      case 'simple':
        return 'compact';
      case 'detailed':
      case 'japan':
      case 'jp':
      case 'full':
      case 'tngon':
        return 'detailed';
    }
  }
  return 'detailed';
}

String _resolveKitchenTemplate(String local, Map<String, dynamic> payload) {
  final value = _firstNonBlank(<String>[
    local,
    _value(payload, <String>['kitchen_template']),
  ]);
  return switch (value.toLowerCase()) {
    'compact' => 'compact',
    'checklist' => 'checklist',
    _ => 'standard',
  };
}

String _receiptLabel(String key, List<String> languages) {
  final labels = <String>[];
  for (final language in languages) {
    final label = _receiptLabelForLanguage(key, language);
    if (label.isNotEmpty && !labels.contains(label)) labels.add(label);
  }
  if (labels.isEmpty) labels.add(_receiptLabelForLanguage(key, 'en'));
  return labels.join(' / ');
}

String _receiptLabelForLanguage(String key, String language) {
  final japanese = <String, String>{
    'date': '日時',
    'order': '伝票',
    'table': 'テーブル',
    'time': '滞在時間',
    'staff': '担当',
    'item': '商品',
    'qty': '数量',
    'amount': '金額',
    'subtotal': '小計',
    'discount': '値引き',
    'surcharge': '追加',
    'total': '合計',
    'qrCode': 'QRメニュー',
    'note': '備考',
    'unknownItem': '商品',
    'tendered': '預り',
    'change': 'お釣り',
    'payment': '支払',
  };
  final vietnamese = <String, String>{
    'date': 'Ngày',
    'order': 'Đơn',
    'table': 'Bàn',
    'time': 'Thời gian',
    'staff': 'Nhân viên',
    'item': 'Món',
    'qty': 'SL',
    'amount': 'Tiền',
    'subtotal': 'Tạm tính',
    'discount': 'Giảm giá',
    'surcharge': 'Phụ thu',
    'total': 'Tổng',
    'qrCode': 'QR menu',
    'note': 'Ghi chú',
    'unknownItem': 'Món',
    'tendered': 'Khách đưa',
    'change': 'Tiền thừa',
    'payment': 'Thanh toán',
  };
  if (language == 'ja') return japanese[key] ?? '';
  if (language == 'vi') return vietnamese[key] ?? '';
  return <String, String>{
        'date': 'Date',
        'order': 'Order',
        'table': 'Table',
        'time': 'Time',
        'staff': 'Staff',
        'item': 'Item',
        'qty': 'Qty',
        'amount': 'Amount',
        'subtotal': 'Subtotal',
        'discount': 'Discount',
        'surcharge': 'Surcharge',
        'total': 'Total',
        'qrCode': 'QR menu',
        'note': 'Note',
        'unknownItem': 'Item',
        'tendered': 'Tendered',
        'change': 'Change',
        'payment': 'Payment',
      }[key] ??
      '';
}

String _receiptItemName(Map<String, dynamic> item, List<String> languages) {
  final names = <String>[];
  final productTranslations = _map(item, <String>['product_name_translations']);
  final nameTranslations = _map(item, <String>['name_translations']);
  final translations = _map(item, <String>['translations']);
  for (final language in languages) {
    final translated = _firstNonBlank(<String>[
      _value(productTranslations, <String>[language]),
      _value(nameTranslations, <String>[language]),
      _value(translations, <String>[language, '${language}_name']),
    ]);
    final direct = _value(item, <String>[
      'product_name_$language',
      'name_$language',
    ]);
    final name = _firstNonBlank(<String>[translated, direct]);
    if (name.isNotEmpty && !names.contains(name)) names.add(name);
  }
  final fallback = _firstNonBlank(<String>[
    _value(item, <String>[
      'open_item_name',
      'item_name',
      'name',
      'product_name',
      'name_snapshot',
    ]),
    '商品',
  ]);
  return names.isEmpty ? fallback : names.join(' / ');
}

String _receiptItemUnitPrice(Map<String, dynamic> item, String currency) {
  final value = _numeric(
    item['unit_price'] ?? item['price'] ?? item['base_price'],
  );
  return value == null || value <= 0 ? '' : _formatMoney(value, currency);
}

String _receiptItemAmount(
  Map<String, dynamic> item,
  num quantity,
  String currency,
) {
  final direct = _valueAsMoney(
    item['line_total'] ??
        item['total_price'] ??
        item['total_amount'] ??
        item['amount'] ??
        item['subtotal'],
    currency,
  );
  if (direct.isNotEmpty) return direct;
  final unit = _numeric(
    item['unit_price'] ?? item['price'] ?? item['base_price'],
  );
  return unit == null ? '' : _formatMoney(unit * quantity, currency);
}

int _columnWidth(String value) {
  var width = 0;
  for (final rune in value.runes) {
    width += _isWideRune(rune) ? 2 : 1;
  }
  return width;
}

bool _isWideRune(int rune) {
  return (rune >= 0x1100 && rune <= 0x11ff) ||
      (rune >= 0x2e80 && rune <= 0xa4cf) ||
      (rune >= 0xac00 && rune <= 0xd7a3) ||
      (rune >= 0xf900 && rune <= 0xfaff) ||
      (rune >= 0xfe10 && rune <= 0xfe6f) ||
      (rune >= 0xff00 && rune <= 0xff60) ||
      (rune >= 0xffe0 && rune <= 0xffe6) ||
      (rune >= 0x1f300 && rune <= 0x1faff);
}

List<String> _wrapText(String value, int width) {
  final limit = math.max(1, width);
  final result = <String>[];
  for (final rawLine in value.split('\n')) {
    final line = _clean(rawLine);
    if (line.isEmpty) {
      continue;
    }
    var current = StringBuffer();
    var currentWidth = 0;
    for (final rune in line.runes) {
      final runeWidth = _isWideRune(rune) ? 2 : 1;
      if (currentWidth == 0 && String.fromCharCode(rune).trim().isEmpty) {
        continue;
      }
      if (currentWidth > 0 && currentWidth + runeWidth > limit) {
        result.add(current.toString());
        current = StringBuffer();
        currentWidth = 0;
      }
      current.write(String.fromCharCode(rune));
      currentWidth += runeWidth;
    }
    if (current.isNotEmpty) result.add(current.toString());
  }
  return result;
}

String _padEndToColumns(String value, int width) {
  final padding = math.max(0, width - _columnWidth(value));
  return '$value${_repeat(' ', padding)}';
}

String _padStartToColumns(String value, int width) {
  final padding = math.max(0, width - _columnWidth(value));
  return '${_repeat(' ', padding)}$value';
}

String _centerText(String value, int width) {
  final text = _clean(value);
  final padding = math.max(0, (width - _columnWidth(text)) ~/ 2);
  return '${_repeat(' ', padding)}$text';
}

List<String> _keyValueLines(String left, String right, int width) {
  if (right.trim().isEmpty) return _wrapText(left, width);
  final rightWidth = math.min(_columnWidth(right), math.max(1, width - 1));
  final leftWidth = math.max(8, width - rightWidth - 1);
  final leftLines = _wrapText(left, leftWidth);
  final rightLines = _wrapText(right, rightWidth);
  final result = <String>[];
  for (var index = 0; index < leftLines.length; index++) {
    final value = leftLines[index];
    if (index == leftLines.length - 1) {
      result.add(
        '${_padEndToColumns(value, width - rightWidth)}${_padStartToColumns(rightLines.first, rightWidth)}',
      );
    } else {
      result.add(value);
    }
  }
  for (final extra in rightLines.skip(1))
    result.add(_padStartToColumns(extra, width));
  return result;
}

int _bigLineWidth(int width) => math.max(8, (width / 1.7).round());

String _shortOrderNo(String value) {
  final text = value.trim();
  if (text.length <= 10) return text;
  final dash = text.lastIndexOf('-');
  if (dash == 8 && RegExp(r'^\d{8}$').hasMatch(text.substring(0, dash))) {
    final tail = text.substring(dash + 1);
    if (tail.isNotEmpty) return tail;
  }
  final compact = text.replaceAll('-', '').toUpperCase();
  return compact.length <= 6 ? compact : compact.substring(0, 6);
}

String _repeat(String value, int count) =>
    List<String>.filled(count, value).join();

class _LineStyle {
  _LineStyle(this.content);

  String content;
  bool big = false;
  bool sans = false;
  bool title = false;
  bool small = false;
  bool invert = false;
  bool center = false;
  bool rule = false;
  bool medium = false;
}

_LineStyle _parseLineStyle(String raw) {
  final style = _LineStyle(raw);
  while (style.content.isNotEmpty) {
    switch (style.content.codeUnitAt(0)) {
      case 1:
        style.big = true;
      case 2:
        style.sans = true;
      case 3:
        style.title = true;
      case 4:
        style.small = true;
      case 5:
        style.invert = true;
      case 6:
        style.center = true;
      case 7:
        style.rule = true;
      case 8:
        style.medium = true;
      default:
        return style;
    }
    style.content = style.content.substring(1);
  }
  return style;
}

class _RasterLine {
  const _RasterLine(this.bitmap, this.centered, this.rule);

  final image.Image bitmap;
  final bool centered;
  final bool rule;
}

/// Splits rendered receipt rows so currency never depends on proportional spaces.
/// ponytail: handles the JPY formats emitted by this gateway; extend for other
/// currencies when their receipt formatter is added.
(String, String)? splitReceiptAmountColumn(String content) {
  final match = RegExp(r'^(.*?)\s+(¥[0-9][0-9,]*)\s*$').firstMatch(content);
  if (match == null) return null;
  final left = match.group(1)?.trimRight() ?? '';
  final right = match.group(2) ?? '';
  return left.isEmpty ? null : (left, right);
}

image.Image renderAndroidTemplateBitmap(
  String text,
  int width, {
  required image.BitmapFont font,
  String? qrData,
}) {
  final columns = width == 384 ? 29 : 38;
  final baseAdvance = math.max(1, font.characterXAdvance('0'));
  final baseScale = (width / columns) / baseAdvance;
  final baseLineHeight = math.max(12, font.lineHeight);
  final rows = <_RasterLine>[];
  for (final rawLine in text.split('\n')) {
    final style = _parseLineStyle(rawLine);
    if (style.rule) {
      final ruleHeight = math.max(
        4,
        (baseLineHeight * baseScale * 0.6).round(),
      );
      final bitmap = image.Image(width: width, height: ruleHeight);
      image.fill(bitmap, color: image.ColorRgb8(255, 255, 255));
      final margin = style.center
          ? (width * 0.33).round()
          : (width * 0.02).round();
      image.fillRect(
        bitmap,
        x1: style.center ? margin : margin,
        y1: ruleHeight ~/ 2,
        x2: style.center ? width - margin : width - margin,
        y2: ruleHeight ~/ 2,
        color: image.ColorRgb8(0, 0, 0),
      );
      rows.add(_RasterLine(bitmap, false, true));
      continue;
    }
    final content = style.content.isEmpty ? ' ' : style.content;
    final nativeWidth = math.max(1, _fontPixelWidth(font, content));
    final styleScale =
        baseScale *
        (style.title
            ? 1.9
            : style.big
            ? 1.7
            : style.medium
            ? 1.3
            : style.small
            ? 0.82
            : 1.0);
    final scale = math.min(styleScale, (width - 16) / nativeWidth);
    final layerWidth = math.max(1, (nativeWidth * scale).round() + 4);
    final layerHeight = math.max(4, (baseLineHeight * scale).round() + 4);
    final amountColumn = !style.invert
        ? splitReceiptAmountColumn(content)
        : null;
    if (amountColumn != null) {
      final row = image.Image(
        width: width - 16,
        height: layerHeight,
        numChannels: 4,
      );
      image.fill(row, color: image.ColorRgba8(0, 0, 0, 0));
      for (final part in <(String, bool)>[
        (amountColumn.$1, false),
        (amountColumn.$2, true),
      ]) {
        final partWidth = math.max(1, _fontPixelWidth(font, part.$1));
        final glyph = image.Image(
          width: partWidth + 4,
          height: baseLineHeight + 4,
          numChannels: 4,
        );
        image.fill(glyph, color: image.ColorRgba8(0, 0, 0, 0));
        image.drawString(
          glyph,
          part.$1,
          font: font,
          x: 2,
          y: 2,
          color: image.ColorRgb8(0, 0, 0),
        );
        final rendered = image.copyResize(
          glyph,
          width: math.max(1, (partWidth * scale).round() + 4),
          height: layerHeight,
          interpolation: image.Interpolation.nearest,
        );
        image.compositeImage(
          row,
          rendered,
          dstX: part.$2 ? row.width - rendered.width : 0,
        );
      }
      rows.add(_RasterLine(row, false, false));
      continue;
    }
    final layer = image.Image(
      width: nativeWidth + 4,
      height: baseLineHeight + 4,
      numChannels: 4,
    );
    image.fill(layer, color: image.ColorRgba8(0, 0, 0, 0));
    if (style.invert) image.fill(layer, color: image.ColorRgb8(0, 0, 0));
    image.drawString(
      layer,
      content,
      font: font,
      x: 2,
      y: 2,
      color: style.invert
          ? image.ColorRgb8(255, 255, 255)
          : image.ColorRgb8(0, 0, 0),
    );
    final scaled = image.copyResize(
      layer,
      width: layerWidth,
      height: layerHeight,
      interpolation: image.Interpolation.nearest,
    );
    if (style.invert) {
      final inverted = image.Image(
        width: width,
        height: scaled.height,
        numChannels: 4,
      );
      image.fill(inverted, color: image.ColorRgb8(0, 0, 0));
      image.compositeImage(
        inverted,
        scaled,
        dstX: style.center ? ((width - scaled.width) / 2).round() : 8,
      );
      rows.add(_RasterLine(inverted, false, false));
    } else {
      rows.add(_RasterLine(scaled, style.center, false));
    }
  }
  final qr = qrData == null || qrData.trim().isEmpty
      ? null
      : _renderQrBitmap(qrData, width);
  final height = math.max(
    24,
    16 +
        rows.fold<int>(0, (sum, row) => sum + row.bitmap.height) +
        (qr?.height ?? 0) +
        (qr == null ? 0 : 16),
  );
  final canvas = image.Image(width: width, height: height);
  image.fill(canvas, color: image.ColorRgb8(255, 255, 255));
  var y = 8;
  for (final row in rows) {
    final x = row.centered ? ((width - row.bitmap.width) / 2).round() : 8;
    image.compositeImage(canvas, row.bitmap, dstX: x, dstY: y);
    y += row.bitmap.height;
  }
  if (qr != null) {
    image.compositeImage(
      canvas,
      qr,
      dstX: ((width - qr.width) / 2).round(),
      dstY: y + 8,
    );
  }
  return canvas;
}

int _fontPixelWidth(image.BitmapFont font, String value) {
  var width = 0;
  for (final unit in value.codeUnits) {
    width += font.characterXAdvance(String.fromCharCode(unit));
  }
  return width;
}

image.Image _renderQrBitmap(String value, int width) {
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
