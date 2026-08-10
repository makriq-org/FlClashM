import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_actions_pinning.dart';

void main() {
  test('accepts remote actions pinned to full commit SHAs', () {
    final failures = findUnpinnedActions('''
steps:
  - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd # v5.0.1
''', sourcePath: '.github/workflows/ci.yaml');

    expect(failures, isEmpty);
  });

  test('rejects tags, branches, and shortened commit SHAs', () {
    final failures = findUnpinnedActions('''
steps:
  - uses: actions/checkout@v5
  - uses: owner/action@main
  - uses: owner/action@93cb6efe
''', sourcePath: '.github/workflows/ci.yaml');

    expect(failures, hasLength(3));
    expect(failures.first, contains('.github/workflows/ci.yaml:2'));
  });

  test('ignores local and Docker actions', () {
    final failures = findUnpinnedActions('''
steps:
  - uses: ./github/actions/local
  - uses: docker://alpine:3.22
''', sourcePath: '.github/workflows/ci.yaml');

    expect(failures, isEmpty);
  });
}
