import 'package:flclashx/product/compile/config_tree.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('copies mutable config containers without JSON conversion', () {
    final marker = Uri.parse('https://example.com');
    final source = <String, dynamic>{
      'nested': <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{'value': 1},
          marker,
        ],
      },
    };

    final copy = copyConfigTree(source);
    final copiedItems = (copy['nested'] as Map)['items'] as List;
    (copiedItems.first as Map)['value'] = 2;

    expect((((source['nested'] as Map)['items'] as List).first as Map)['value'],
        1);
    expect(copiedItems[1], same(marker));
  });
}
