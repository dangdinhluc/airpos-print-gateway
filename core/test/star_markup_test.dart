import 'package:airpos_print_gateway_core/src/star_markup.dart';
import 'package:test/test.dart';

void main() {
  test('converts receipt lines to UTF-8 Star markup columns', () {
    final markup = StarMarkup.receipt('''ワビ酒場高松
小計                         ¥1,480
消費税(10%)                    ¥135
合計                         ¥1,480''');

    expect(markup, startsWith('[font: b]\n[linespacing: min]'));
    expect(markup, isNot(contains('[feed: 1]')));
    expect(markup, contains('ワビ酒場高松'));
    expect(markup, contains('[column: left 小計; right ¥1,480]'));
    expect(markup, contains('[column: left 消費税(10%); right ¥135]'));
    expect(markup, contains('[column: left 合計; right ¥1,480]'));
  });
}
