import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flclashx/product/compile/byedpi_cli_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const validator = ByedpiCliValidator();

  test('option table describes short and long forms and all input contexts',
      () {
    expect(byedpiCliOptions, isNotEmpty);
    for (final option in byedpiCliOptions) {
      expect(option.shortName, hasLength(1));
      expect(option.longName, isNotEmpty);
      expect(option.valueKind, isNotNull, reason: option.longName);
      expect(option.repeatable, isNotNull, reason: option.longName);
      expect(option.contexts, isNotEmpty, reason: option.longName);
    }
  });

  test('accepts long equals, attached short values, and short clusters', () {
    final result = validator.validate(
      '--fake=-1 -f-1 -Qr -S -a1',
      path: 'byedpi.args',
      context: ByedpiCliContext.args,
    );

    expect(result.arguments, ['--fake=-1', '-f-1', '-Qr', '-S', '-a1']);
    expect(
      result.options.map((option) => (option.name, option.value)).toList(),
      [
        ('fake', '-1'),
        ('fake', '-1'),
        ('fake-tls-mod', 'r'),
        ('md5sig', null),
        ('udp-fake', '1'),
      ],
    );
  });

  test('preserves shell argument order and validates quoted inline data', () {
    final result = validator.validate(
      r'''--hosts ':example.com test.example' --ipset=:1.1.1.1/32 --fake-data ':abc\x20def' -s3:5+sm''',
      path: 'byedpi.strategies[3]',
      context: ByedpiCliContext.strategy,
    );

    expect(result.options.map((option) => option.name), [
      'hosts',
      'ipset',
      'fake-data',
      'split',
    ]);
    expect(result.options.first.value, ':example.com test.example');
  });

  test('accepts every bundled ByeByeDPI strategy line', () {
    final asset = File(
      'assets/runtimes/byedpi/android/byebyeedpi-strategies.list',
    );
    expect(
      sha256.convert(asset.readAsBytesSync()).toString(),
      '0d853dea8a82634d64768eb6252b6e9bdeab5abce1883666ca4f2e223f21d824',
    );
    final lines = asset.readAsLinesSync();
    expect(lines, hasLength(60));
    final failures = <String>[];
    for (var index = 0; index < lines.length; index++) {
      try {
        validator.validate(
          lines[index],
          path: 'byedpi.strategies[$index]',
          context: ByedpiCliContext.strategy,
        );
      } on FormatException catch (error) {
        failures.add('line ${index + 1}: ${lines[index]}\n$error');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n\n'));
  });

  test('rejects client-owned, path-backed, and undocumented internal flags',
      () {
    final forbidden = <String>[
      '--ip=127.0.0.1',
      '-p1080',
      '--no-domain',
      '--no-udp',
      '--conn-ip=127.0.0.1',
      '--buf-size=4096',
      '--max-conn=10',
      '--debug=1',
      '--tfo',
      '--timeout=1',
      '--def-ttl=8',
      '--daemon',
      '--pidfile=/tmp/byedpi.pid',
      '--transparent',
      '--protect-path=/tmp/protect',
      '--cache-file=/tmp/cache',
      '--copy=1',
      '--wait-send',
      '--await-int=1',
      '--connect-to=socks5://127.0.0.1:1080',
      '--comment=value',
      '--cache-merge=1',
      '--no-ipv6',
    ];
    for (final value in forbidden) {
      expect(
        () => validator.validate(
          value,
          path: 'byedpi.fallback-args',
          context: ByedpiCliContext.fallbackArgs,
        ),
        throwsA(
          isA<FormatException>()
              .having(
                (error) => error.message,
                'path',
                contains('byedpi.fallback-args'),
              )
              .having(
                (error) => error.message,
                'reason',
                contains('forbidden'),
              ),
        ),
        reason: value,
      );
    }
  });

  test('allows only inline hosts, ipset, and fake-data values', () {
    for (final value in [
      '--hosts=:example.com',
      '--ipset=:1.1.1.1/32',
      r'--fake-data=:hello\x20world',
    ]) {
      expect(
        () => validator.validate(
          value,
          path: 'byedpi.args',
          context: ByedpiCliContext.args,
        ),
        returnsNormally,
        reason: value,
      );
    }
    for (final value in [
      '--hosts=hosts.txt',
      '--ipset=/tmp/ipset',
      '--fake-data=fake.bin',
    ]) {
      expect(
        () => validator.validate(
          value,
          path: 'byedpi.args',
          context: ByedpiCliContext.args,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('byedpi.args'), contains('inline')),
          ),
        ),
        reason: value,
      );
    }
  });

  test('validates position, filter, and modifier grammars', () {
    for (final value in [
      '-s-1',
      '-s1:1:0',
      '-d3:5+sm',
      '-f1+nme',
      '--tlsrec=65535',
      '--tlsrec=0xffff',
      '--pf=80-443',
      '--round=1-5',
      '--proto=t,h,u,i',
      '--fake-tls-mod=rand,orig,msize=1200',
      '--mod-http=h,d,r',
    ]) {
      expect(
        () => validator.validate(
          value,
          path: 'byedpi.strategies[0]',
          context: ByedpiCliContext.strategy,
        ),
        returnsNormally,
        reason: value,
      );
    }
    for (final value in [
      '-s1:0',
      '-d1+z',
      '--tlsrec=65536',
      '--tlsrec=0x10000',
      '--pf=0',
      '--round=5-1',
      '--proto=t,b',
      '--fake-tls-mod=msize=nope',
      '--mod-http=h,x',
    ]) {
      expect(
        () => validator.validate(
          value,
          path: 'byedpi.strategies[3]',
          context: ByedpiCliContext.strategy,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('byedpi.strategies[3]'),
          ),
        ),
        reason: value,
      );
    }
  });

  test('rejects missing values, unexpected values, and duplicates', () {
    for (final value in [
      '--fake',
      '--md5sig=value',
      '--tlsminor 1 --tlsminor 2',
      "--hosts='unterminated",
      r'--hosts=:value\',
    ]) {
      expect(
        () => validator.validate(
          value,
          path: 'byedpi.args',
          context: ByedpiCliContext.args,
        ),
        throwsA(isA<FormatException>()),
        reason: value,
      );
    }
    expect(
      () => validator.validate(
        '--split=1 --split=2',
        path: 'byedpi.args',
        context: ByedpiCliContext.args,
      ),
      returnsNormally,
    );
  });
}
