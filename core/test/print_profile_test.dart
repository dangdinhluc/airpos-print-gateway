import 'dart:convert';
import 'dart:io';

import 'package:airpos_print_gateway_core/airpos_print_gateway_core.dart';
import 'package:test/test.dart';

void main() {
  test('defaults and schema stay stable', () {
    final profile = StorePrintProfile();

    expect(profile.storeName, isEmpty);
    expect(profile.currency, 'JPY');
    expect(profile.templateSettings.receiptTemplate, 'modern');
    expect(profile.templateSettings.kitchenTemplate, 'standard');
    expect(profile.templateSettings.languages, <String>['vi', 'ja']);
    expect(profile.templateSettings.showOrderNumber, isTrue);
    expect(profile.templateSettings.showTable, isTrue);
    expect(profile.templateSettings.showDateTime, isTrue);
    expect(profile.templateSettings.showStaffName, isTrue);
    expect(profile.templateSettings.showQrCode, isFalse);
    expect(profile.templateSettings.showTimeSeated, isFalse);
  });

  test('JSON round-trips without leaking secret fields', () {
    final profile = StorePrintProfile(
      storeName: 'LUC MART',
      storeNameJa: 'ルクマート',
      address: '123 Tokyo St',
      phone: '+81-90-0000-0000',
      taxId: 'TAX-1',
      currency: 'JPY',
      headerTextVi: 'Xin chao',
      headerTextJa: 'いらっしゃいませ',
      footerTextVi: 'Cam on',
      footerTextJa: 'ありがとうございました',
      templateSettings: TemplateSettings(
        receiptTemplate: 'detailed',
        kitchenTemplate: 'checklist',
        languages: <String>['vi', 'ja', 'en'],
        showOrderNumber: false,
        showTable: false,
        showDateTime: true,
        showStaffName: false,
        showQrCode: true,
        showTimeSeated: true,
      ),
      lastSyncedAt: '2026-08-15T00:00:00.000Z',
      localEditedAt: '2026-08-15T01:00:00.000Z',
    );

    final json = profile.toJson();
    final copy = StorePrintProfile.fromJson(Map<String, dynamic>.from(json));

    expect(copy.toJson(), json);
    expect(json.keys, isNot(contains('supabase_url')));
    expect(json.keys, isNot(contains('supabase_anon_key')));
    expect(json.keys, isNot(contains('password')));
    expect(json.keys, isNot(contains('access_token')));
    expect(json.keys, isNot(contains('gateway_token')));
  });

  test('normalizes receipt and kitchen templates with allowlists', () {
    final profile = StorePrintProfile.fromJson(<String, dynamic>{
      'template_settings': <String, dynamic>{
        'receipt_template': 'JAPAN',
        'kitchen_template': 'unknown-value',
        'languages': <Object?>['vn', 'jp', 'ja', 'xx'],
      },
    });

    expect(profile.templateSettings.receiptTemplate, 'detailed');
    expect(profile.templateSettings.kitchenTemplate, 'standard');
    expect(profile.templateSettings.languages, <String>['vi', 'ja']);
  });

  test('normalizes languages and keeps the allowlist compact', () {
    final profile = TemplateSettings(
      languages: <String>['VN', 'ja', 'en', 'cn', 'kr', 'mm', 'zz'],
    );

    expect(profile.languages, <String>['vi', 'ja', 'en', 'zh', 'ko', 'my']);
  });

  test('maps seed response fields into store and receipt settings', () {
    final profile = StorePrintProfile.fromSeed(<String, dynamic>{
      'synced_at': '2026-08-15T02:03:04.000Z',
      'store_settings': <String, dynamic>{
        'store_name': 'Seed Store',
        'address_ja': '東京',
        'telephone': '03-0000-0000',
        'currency': 'VND',
      },
      'receipt_settings': <String, dynamic>{
        'receipt_template': 'compact',
        'kitchen_template': 'checklist',
        'languages': <Object?>['vn', 'jp'],
        'show_order_number': false,
        'show_table': false,
        'show_date': true,
        'show_time': false,
        'show_cashier': true,
        'show_qr_code': true,
        'show_time_seated': true,
      },
    });

    expect(profile.storeName, 'Seed Store');
    expect(profile.address, '東京');
    expect(profile.phone, '03-0000-0000');
    expect(profile.currency, 'VND');
    expect(profile.templateSettings.receiptTemplate, 'compact');
    expect(profile.templateSettings.kitchenTemplate, 'checklist');
    expect(profile.templateSettings.languages, <String>['vi', 'ja']);
    expect(profile.templateSettings.showOrderNumber, isFalse);
    expect(profile.templateSettings.showTable, isFalse);
    expect(profile.templateSettings.showDateTime, isTrue);
    expect(profile.templateSettings.showStaffName, isTrue);
    expect(profile.templateSettings.showQrCode, isTrue);
    expect(profile.templateSettings.showTimeSeated, isTrue);
    expect(profile.lastSyncedAt, '2026-08-15T02:03:04.000Z');
    expect(profile.localEditedAt, isNull);
  });

  test('seed without synced_at preserves a null sync timestamp', () {
    final profile = StorePrintProfile.fromSeed(<String, dynamic>{
      'store_settings': <String, dynamic>{},
      'receipt_settings': <String, dynamic>{},
    });

    expect(profile.lastSyncedAt, isNull);
    expect(profile.localEditedAt, isNull);
  });

  test('markLocalEdited and markSynced update sync markers', () {
    final original = StorePrintProfile(
      lastSyncedAt: '2026-08-15T00:00:00.000Z',
    );

    final edited = original.markLocalEdited('2026-08-15T03:00:00.000Z');
    final synced = edited.markSynced('2026-08-15T04:00:00.000Z');

    expect(edited.localEditedAt, '2026-08-15T03:00:00.000Z');
    expect(edited.lastSyncedAt, '2026-08-15T00:00:00.000Z');
    expect(synced.lastSyncedAt, '2026-08-15T04:00:00.000Z');
    expect(synced.localEditedAt, isNull);
  });

  test(
    'GatewayConfigStore loads missing or corrupt print profile as default',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'airpos-profile-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final store = GatewayConfigStore(configDirectory: directory.path);

      final missing = await store.loadPrintProfile();
      expect(missing.toJson(), StorePrintProfile().toJson());

      await store.printProfileFile.writeAsString('{');

      final corrupt = await store.loadPrintProfile();
      expect(corrupt.toJson(), StorePrintProfile().toJson());
    },
  );

  test('GatewayConfigStore saves print profile atomically', () async {
    final directory = await Directory.systemTemp.createTemp('airpos-profile-');
    addTearDown(() => directory.delete(recursive: true));

    final store = GatewayConfigStore(configDirectory: directory.path);
    final profile = StorePrintProfile(
      storeName: 'Atomic Shop',
      templateSettings: TemplateSettings(
        receiptTemplate: 'classic',
        kitchenTemplate: 'compact',
      ),
    );

    await store.savePrintProfile(profile, markLocalEdited: false);

    final saved =
        jsonDecode(await store.printProfileFile.readAsString())
            as Map<String, dynamic>;

    expect(await File('${store.printProfileFile.path}.tmp').exists(), isFalse);
    expect(saved['store_name'], 'Atomic Shop');
    expect(saved['template_settings']['receipt_template'], 'classic');
    expect(saved['template_settings']['kitchen_template'], 'compact');
    expect(saved['local_edited_at'], isNull);
  });
}
