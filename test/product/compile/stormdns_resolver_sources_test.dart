import 'dart:io';

import 'package:flclashx/product/compile/stormdns_resolver_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = StormDnsResolverSourceParser();

  group('literal expansion matches StormDNS', () {
    test('single addresses keep the default port unless one is given', () {
      expect(parser.expandLiteral('8.8.8.8')!.single.line, '8.8.8.8');
      expect(parser.expandLiteral('1.1.1.1:5353')!.single.line, '1.1.1.1:5353');
      expect(
        parser.expandLiteral('[2001:4860:4860::8888]:53')!.single.ip,
        '2001:4860:4860::8888',
      );
    });

    test('IPv4 CIDR drops the network and broadcast addresses', () {
      expect(
        parser.expandLiteral('192.168.1.0/30')!.map((e) => e.ip),
        ['192.168.1.1', '192.168.1.2'],
      );
      expect(parser.expandLiteral('172.16.0.0/24')!.length, 254);
    });

    test('/31 and /32 expand to the whole prefix', () {
      expect(
        parser.expandLiteral('10.0.0.0/31')!.map((e) => e.ip),
        ['10.0.0.0', '10.0.0.1'],
      );
      expect(parser.expandLiteral('10.0.0.5/32')!.single.ip, '10.0.0.5');
    });

    test('IPv6 CIDR keeps the last address', () {
      expect(
        parser.expandLiteral('2001:db8::/126')!.map((e) => e.ip),
        ['2001:db8::1', '2001:db8::2', '2001:db8::3'],
      );
    });

    test('a CIDR carries its port to every expanded address', () {
      expect(
        parser.expandLiteral('192.168.1.0/30:5353')!.map((e) => e.line),
        ['192.168.1.1:5353', '192.168.1.2:5353'],
      );
    });

    test('ranges past the host limit expand to nothing', () {
      expect(parser.expandLiteral('1.0.0.0/1'), isEmpty);
      expect(parser.expandLiteral('2001:db8::/64'), isEmpty);
    });

    test('malformed tokens are rejected', () {
      for (final token in const [
        'not-an-ip',
        '8.8.8.8:0',
        '8.8.8.8:70000',
        '256.1.1.1',
        '1:2:3:4:5:6:7:8::',
        '1:2:3:4:5:6:7::8',
        '192.0.2.1::',
        '',
      ]) {
        expect(parser.expandLiteral(token), anyOf(isNull, isEmpty),
            reason: token);
      }
    });

    test('mapped IPv4 is canonicalized before de-duplication', () {
      expect(
        parser.expandLiteral('[::ffff:8.8.8.8]:5353')!.single.line,
        '8.8.8.8:5353',
      );
      final lines = buildResolverFileLines(
        sources: parser.parse(
          ['[::ffff:8.8.8.8]:5353', '8.8.8.8'],
          label: 'r',
        ),
        remoteLists: const {},
      );
      expect(lines, ['8.8.8.8:5353']);
    });
  });

  group('source list parsing', () {
    test('an absent or empty list falls back to system DNS', () {
      expect(parser.parse(null, label: 'r').single,
          isA<StormDnsSystemResolverSource>());
      expect(parser.parse(<String>[], label: 'r').single,
          isA<StormDnsSystemResolverSource>());
    });

    test('mixed sources keep their declared order', () {
      final sources = parser.parse(
        ['system', '8.8.8.8', '192.168.1.0/30', 'https://example.com/r.txt'],
        label: 'r',
      );
      expect(sources[0], isA<StormDnsSystemResolverSource>());
      expect(sources[1], isA<StormDnsLiteralResolverSource>());
      expect(sources[2], isA<StormDnsLiteralResolverSource>());
      expect(sources[3], isA<StormDnsRemoteResolverSource>());
    });

    test('a malformed literal is a profile error, not a silent skip', () {
      expect(
        () => parser.parse(['nonsense'], label: 'r'),
        throwsA(isA<FormatException>()),
      );
    });

    test('an over-sized CIDR is reported instead of expanding', () {
      expect(
        () => parser.parse(['1.0.0.0/1'], label: 'r'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('list address safety', () {
    test('only public https addresses are accepted', () {
      for (final url in const [
        'http://example.com/r.txt',
        'https://user:pass@example.com/r.txt',
        'https://example.com/r.txt#frag',
        'https://localhost/r.txt',
        'https://127.0.0.1/r.txt',
        'https://10.1.2.3/r.txt',
        'https://192.168.0.1/r.txt',
        'https://[::1]/r.txt',
        'https://[::ffff:127.0.0.1]/r.txt',
        'https://localhost./r.txt',
      ]) {
        expect(
          () => parser.parse([url], label: 'r'),
          throwsA(isA<FormatException>()),
          reason: url,
        );
      }
      expect(
        parser.parse(['https://example.com/r.txt'], label: 'r').single,
        isA<StormDnsRemoteResolverSource>(),
      );
    });

    test('private addresses are still allowed inside a list', () {
      final entries = parseResolverListBody('10.1.2.3\n192.168.5.5:5353\n');
      expect(entries.map((e) => e.line), ['10.1.2.3', '192.168.5.5:5353']);
    });
  });

  group('resolver file lines', () {
    test('duplicates are dropped by IP, first port wins', () {
      final lines = buildResolverFileLines(
        sources: parser.parse(
          ['8.8.8.8:5353', '8.8.8.8', '1.1.1.1'],
          label: 'r',
        ),
        remoteLists: const {},
      );
      expect(lines, ['8.8.8.8:5353', '1.1.1.1']);
    });

    test('system is emitted once, in place', () {
      final lines = buildResolverFileLines(
        sources: parser.parse(['1.1.1.1', 'system', 'system'], label: 'r'),
        remoteLists: const {},
      );
      expect(lines, ['1.1.1.1', stormDnsSystemDnsPlaceholder]);
    });

    test('an unavailable remote list is skipped, the rest survive', () {
      final lines = buildResolverFileLines(
        sources: parser.parse(
          ['https://example.com/r.txt', '9.9.9.9'],
          label: 'r',
        ),
        remoteLists: const {},
      );
      expect(lines, ['9.9.9.9']);
    });

    test('remote entries are merged in order and de-duplicated', () {
      final url = Uri.parse('https://example.com/r.txt');
      final lines = buildResolverFileLines(
        sources: parser.parse(['8.8.8.8', url.toString()], label: 'r'),
        remoteLists: {
          url: StormDnsRemoteResolverList(
            entries: const [
              StormDnsResolverEntry(ip: '8.8.8.8', port: 5353),
              StormDnsResolverEntry(ip: '9.9.9.9', port: 53),
            ],
            fetchedAt: DateTime(2026),
          ),
        },
      );
      expect(lines, ['8.8.8.8', '9.9.9.9']);
    });
  });

  group('remote list cache', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('stormdns-lists-');
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('first run with no cache and an unreachable list yields nothing',
        () async {
      final store = DefaultStormDnsRemoteResolverListStore(
        cacheDirectoryPath: tempDir.path,
        download: (_) async => null,
      );
      final result = await store.resolve(
        [Uri.parse('https://example.com/r.txt')],
        refresh: const Duration(hours: 24),
      );
      expect(result, isEmpty);
    });

    test('a fetched list is cached and reused inside the refresh window',
        () async {
      var downloads = 0;
      final url = Uri.parse('https://example.com/r.txt');
      var now = DateTime(2026, 1, 1);
      final store = DefaultStormDnsRemoteResolverListStore(
        cacheDirectoryPath: tempDir.path,
        download: (_) async {
          downloads++;
          return '8.8.8.8\n';
        },
        now: () => now,
      );

      await store.resolve([url], refresh: const Duration(hours: 24));
      expect(downloads, 1);

      now = DateTime(2026, 1, 1, 12);
      final second =
          await store.resolve([url], refresh: const Duration(hours: 24));
      expect(downloads, 1, reason: 'still fresh');
      expect(second[url]!.entries.single.ip, '8.8.8.8');
    });

    test('an unreachable list falls back to its stale copy', () async {
      final url = Uri.parse('https://example.com/r.txt');
      var now = DateTime(2026, 1, 1);
      var body = '8.8.8.8\n';
      var failing = false;
      final store = DefaultStormDnsRemoteResolverListStore(
        cacheDirectoryPath: tempDir.path,
        download: (_) async => failing ? null : body,
        now: () => now,
      );

      await store.resolve([url], refresh: const Duration(hours: 1));

      now = DateTime(2026, 1, 5);
      failing = true;
      final stale =
          await store.resolve([url], refresh: const Duration(hours: 1));
      expect(stale[url]!.entries.single.ip, '8.8.8.8',
          reason: 'stale copy is better than dropping the source');

      failing = false;
      body = '9.9.9.9\n';
      final refreshed =
          await store.resolve([url], refresh: const Duration(hours: 1));
      expect(refreshed[url]!.entries.single.ip, '9.9.9.9');
    });

    test('each list address is cached separately', () async {
      final first = Uri.parse('https://a.example.com/r.txt');
      final second = Uri.parse('https://b.example.com/r.txt');
      final store = DefaultStormDnsRemoteResolverListStore(
        cacheDirectoryPath: tempDir.path,
        download: (url) async => url == first ? '8.8.8.8\n' : '9.9.9.9\n',
        now: () => DateTime(2026),
      );

      final result = await store
          .resolve([first, second], refresh: const Duration(hours: 1));
      expect(result[first]!.entries.single.ip, '8.8.8.8');
      expect(result[second]!.entries.single.ip, '9.9.9.9');
      expect(tempDir.listSync().length, 2);
    });

    test('invalid lines inside a fetched list are skipped', () {
      final entries = parseResolverListBody(
        '# comment\n\n8.8.8.8\nnonsense\n1.1.1.1:5353\n',
      );
      expect(entries.map((e) => e.line), ['8.8.8.8', '1.1.1.1:5353']);
    });
  });
}
