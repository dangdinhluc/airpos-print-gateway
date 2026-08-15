const List<String> _defaultPrintLanguages = <String>['vi', 'ja'];
const Object _unset = Object();

class TemplateSettings {
  TemplateSettings({
    String? receiptTemplate,
    String? kitchenTemplate,
    List<String>? languages,
    bool? showOrderNumber,
    bool? showTable,
    bool? showDateTime,
    bool? showStaffName,
    bool? showQrCode,
    bool? showTimeSeated,
  }) : receiptTemplate = _normalizeReceiptTemplate(receiptTemplate),
       kitchenTemplate = _normalizeKitchenTemplate(kitchenTemplate),
       languages = List<String>.unmodifiable(_normalizeLanguages(languages)),
       showOrderNumber = showOrderNumber ?? true,
       showTable = showTable ?? true,
       showDateTime = showDateTime ?? true,
       showStaffName = showStaffName ?? true,
       showQrCode = showQrCode ?? false,
       showTimeSeated = showTimeSeated ?? false;

  final String receiptTemplate;
  final String kitchenTemplate;
  final List<String> languages;
  final bool showOrderNumber;
  final bool showTable;
  final bool showDateTime;
  final bool showStaffName;
  final bool showQrCode;
  final bool showTimeSeated;

  factory TemplateSettings.fromJson(Map<String, dynamic> json) {
    return TemplateSettings(
      receiptTemplate: _asString(json['receipt_template']),
      kitchenTemplate: _asString(json['kitchen_template']),
      languages: _normalizeLanguages(json['languages']),
      showOrderNumber: _boolValue(json['show_order_number']),
      showTable: _boolValue(json['show_table']),
      showDateTime: _boolValue(json['show_date_time']),
      showStaffName: _boolValue(json['show_staff_name']),
      showQrCode: _boolValue(json['show_qr_code']),
      showTimeSeated: _boolValue(json['show_time_seated']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'receipt_template': receiptTemplate,
    'kitchen_template': kitchenTemplate,
    'languages': List<String>.from(languages),
    'show_order_number': showOrderNumber,
    'show_table': showTable,
    'show_date_time': showDateTime,
    'show_staff_name': showStaffName,
    'show_qr_code': showQrCode,
    'show_time_seated': showTimeSeated,
  };

  TemplateSettings copyWith({
    String? receiptTemplate,
    String? kitchenTemplate,
    List<String>? languages,
    bool? showOrderNumber,
    bool? showTable,
    bool? showDateTime,
    bool? showStaffName,
    bool? showQrCode,
    bool? showTimeSeated,
  }) {
    return TemplateSettings(
      receiptTemplate: receiptTemplate ?? this.receiptTemplate,
      kitchenTemplate: kitchenTemplate ?? this.kitchenTemplate,
      languages: languages ?? this.languages,
      showOrderNumber: showOrderNumber ?? this.showOrderNumber,
      showTable: showTable ?? this.showTable,
      showDateTime: showDateTime ?? this.showDateTime,
      showStaffName: showStaffName ?? this.showStaffName,
      showQrCode: showQrCode ?? this.showQrCode,
      showTimeSeated: showTimeSeated ?? this.showTimeSeated,
    );
  }
}

class StorePrintProfile {
  StorePrintProfile({
    String? storeName,
    String? storeNameJa,
    String? address,
    String? phone,
    String? taxId,
    String? currency,
    String? headerTextVi,
    String? headerTextJa,
    String? footerTextVi,
    String? footerTextJa,
    TemplateSettings? templateSettings,
    String? lastSyncedAt,
    String? localEditedAt,
  }) : storeName = _nonEmptyString(storeName, ''),
       storeNameJa = _asString(storeNameJa) ?? '',
       address = _asString(address) ?? '',
       phone = _asString(phone) ?? '',
       taxId = _asString(taxId) ?? '',
       currency = _nonEmptyString(currency, 'JPY'),
       headerTextVi = _asString(headerTextVi) ?? '',
       headerTextJa = _asString(headerTextJa) ?? '',
       footerTextVi = _asString(footerTextVi) ?? '',
       footerTextJa = _asString(footerTextJa) ?? '',
       templateSettings = templateSettings ?? TemplateSettings(),
       lastSyncedAt = _asString(lastSyncedAt),
       localEditedAt = _asString(localEditedAt);

  final String storeName;
  final String storeNameJa;
  final String address;
  final String phone;
  final String taxId;
  final String currency;
  final String headerTextVi;
  final String headerTextJa;
  final String footerTextVi;
  final String footerTextJa;
  final TemplateSettings templateSettings;
  final String? lastSyncedAt;
  final String? localEditedAt;

  factory StorePrintProfile.fromJson(Map<String, dynamic> json) {
    final templates = _asMap(json['template_settings']);
    return StorePrintProfile(
      storeName: _asString(json['store_name']),
      storeNameJa: _asString(json['store_name_ja']),
      address: _asString(json['address']),
      phone: _asString(json['phone']),
      taxId: _asString(json['tax_id']),
      currency: _asString(json['currency']),
      headerTextVi: _asString(json['header_text_vi']),
      headerTextJa: _asString(json['header_text_ja']),
      footerTextVi: _asString(json['footer_text_vi']),
      footerTextJa: _asString(json['footer_text_ja']),
      templateSettings: templates == null
          ? null
          : TemplateSettings.fromJson(templates),
      lastSyncedAt: _asString(json['last_synced_at']),
      localEditedAt: _asString(json['local_edited_at']),
    );
  }

  factory StorePrintProfile.fromSeed(Map<String, dynamic> response) {
    final store = _asMap(response['store_settings']) ?? <String, dynamic>{};
    final receipt = _asMap(response['receipt_settings']) ?? <String, dynamic>{};
    final explicitShowDateTime = _boolValue(receipt['show_date_time']);
    final showDateTime =
        explicitShowDateTime ??
        ((_boolValue(receipt['show_date']) ?? true) ||
            (_boolValue(receipt['show_time']) ?? true));

    return StorePrintProfile(
      storeName: _firstNonBlank(store, <String>['store_name', 'brand_name']),
      storeNameJa: _asString(store['store_name_ja']),
      address: _firstNonBlank(store, <String>['address_ja', 'address']),
      phone: _firstNonBlank(store, <String>['phone', 'telephone', 'hotline']),
      taxId: _asString(store['tax_id']),
      currency: _asString(store['currency']),
      headerTextVi: _asString(receipt['header_text_vi']),
      headerTextJa: _asString(receipt['header_text_ja']),
      footerTextVi: _asString(receipt['footer_text_vi']),
      footerTextJa: _asString(receipt['footer_text_ja']),
      templateSettings: TemplateSettings(
        receiptTemplate: _firstNonBlank(receipt, <String>[
          'receipt_template',
          'template',
        ]),
        kitchenTemplate: _firstNonBlank(receipt, <String>['kitchen_template']),
        languages: _normalizeLanguages(receipt['languages']),
        showOrderNumber: _boolValue(receipt['show_order_number']),
        showTable: _boolValue(receipt['show_table']),
        showDateTime: showDateTime,
        showStaffName:
            _boolValue(receipt['show_staff_name']) ??
            _boolValue(receipt['show_cashier']),
        showQrCode: _boolValue(receipt['show_qr_code']),
        showTimeSeated: _boolValue(receipt['show_time_seated']),
      ),
      lastSyncedAt: _asString(response['synced_at']),
      localEditedAt: null,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'store_name': storeName,
    'store_name_ja': storeNameJa,
    'address': address,
    'phone': phone,
    'tax_id': taxId,
    'currency': currency,
    'header_text_vi': headerTextVi,
    'header_text_ja': headerTextJa,
    'footer_text_vi': footerTextVi,
    'footer_text_ja': footerTextJa,
    'template_settings': templateSettings.toJson(),
    'last_synced_at': lastSyncedAt,
    'local_edited_at': localEditedAt,
  };

  StorePrintProfile copyWith({
    String? storeName,
    String? storeNameJa,
    String? address,
    String? phone,
    String? taxId,
    String? currency,
    String? headerTextVi,
    String? headerTextJa,
    String? footerTextVi,
    String? footerTextJa,
    TemplateSettings? templateSettings,
    Object? lastSyncedAt = _unset,
    Object? localEditedAt = _unset,
  }) {
    return StorePrintProfile(
      storeName: storeName ?? this.storeName,
      storeNameJa: storeNameJa ?? this.storeNameJa,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      taxId: taxId ?? this.taxId,
      currency: currency ?? this.currency,
      headerTextVi: headerTextVi ?? this.headerTextVi,
      headerTextJa: headerTextJa ?? this.headerTextJa,
      footerTextVi: footerTextVi ?? this.footerTextVi,
      footerTextJa: footerTextJa ?? this.footerTextJa,
      templateSettings: templateSettings ?? this.templateSettings,
      lastSyncedAt: identical(lastSyncedAt, _unset)
          ? this.lastSyncedAt
          : _markerValue(lastSyncedAt),
      localEditedAt: identical(localEditedAt, _unset)
          ? this.localEditedAt
          : _markerValue(localEditedAt),
    );
  }

  StorePrintProfile markLocalEdited([Object? timestamp, Object? now]) {
    return copyWith(localEditedAt: _timestamp(now ?? timestamp));
  }

  StorePrintProfile markSynced([Object? timestamp, Object? now]) {
    return copyWith(
      lastSyncedAt: _timestamp(now ?? timestamp),
      localEditedAt: null,
    );
  }
}

String _normalizeReceiptTemplate(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'classic' => 'classic',
    'compact' || 'simple' => 'compact',
    'detailed' || 'japan' || 'jp' || 'full' || 'tngon' => 'detailed',
    _ => 'modern',
  };
}

String _normalizeKitchenTemplate(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'compact' => 'compact',
    'checklist' => 'checklist',
    _ => 'standard',
  };
}

List<String> _normalizeLanguages(Object? raw) {
  final normalized = <String>[];
  if (raw is List) {
    for (final item in raw) {
      if (item is! String) continue;
      final language = switch (item.trim().toLowerCase()) {
        'vi' || 'vn' => 'vi',
        'ja' || 'jp' => 'ja',
        'en' => 'en',
        'zh' || 'cn' => 'zh',
        'ko' || 'kr' => 'ko',
        'id' => 'id',
        'my' || 'mm' => 'my',
        _ => null,
      };
      if (language != null && !normalized.contains(language)) {
        normalized.add(language);
      }
    }
  }
  return normalized.isEmpty
      ? List<String>.from(_defaultPrintLanguages)
      : normalized;
}

String? _asString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

String _nonEmptyString(String? value, String fallback) =>
    _asString(value) ?? fallback;

bool? _boolValue(Object? value) => value is bool ? value : null;

Map<String, dynamic>? _asMap(Object? value) {
  if (value is! Map) return null;
  try {
    return Map<String, dynamic>.from(value);
  } catch (_) {
    return null;
  }
}

String? _firstNonBlank(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = _asString(json[key]);
    if (value != null) return value;
  }
  return null;
}

String? _markerValue(Object? value) {
  if (value is DateTime) return value.toUtc().toIso8601String();
  return _asString(value);
}

String _timestamp([Object? value]) =>
    _markerValue(value) ?? DateTime.now().toUtc().toIso8601String();
