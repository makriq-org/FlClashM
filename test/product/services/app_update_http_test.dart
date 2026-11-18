import 'dart:typed_data';

import 'package:flclashx/product/services/app_update_http.dart';
import 'package:flutter_test/flutter_test.dart';

/// Отвечает заранее заданными шагами и запоминает адреса.
class _FakeClient implements AppUpdateHttpClient {
  _FakeClient(this.steps);

  final Map<String, AppUpdateHttpResponse> steps;
  final requested = <Uri>[];
  int? lastMaxBytes;

  @override
  Future<AppUpdateHttpResponse> open(
    Uri url, {
    required int maxBytes,
    required Duration deadline,
  }) async {
    requested.add(url);
    lastMaxBytes = maxBytes;
    return steps[url.toString()] ??
        const AppUpdateHttpResponse(statusCode: 404);
  }

  @override
  Future<List<dynamic>> readJsonList(String url) =>
      throw UnsupportedError('unused');

  @override
  Future<String?> readText(String url) async => null;

  @override
  Future<void> download(
    String url,
    String targetPath, {
    void Function(int received, int total)? onReceiveProgress,
    AppUpdateDownloadCancellation? cancellation,
    int? expectedLength,
  }) => throw UnsupportedError('unused');
}

void main() {
  final manifestUrl = Uri.parse(
    'https://mirror.example/update/stable.json',
  );

  test('returns the body of a single HTTPS answer', () async {
    final client = _FakeClient({
      manifestUrl.toString(): AppUpdateHttpResponse(
        statusCode: 200,
        body: Uint8List.fromList([1, 2, 3]),
      ),
    });

    final body = await fetchAppUpdateDocument(
      client,
      manifestUrl,
      maxBytes: 1024,
    );

    expect(body, [1, 2, 3]);
    expect(client.lastMaxBytes, 1024);
  });

  test('checks every redirect hop and refuses a plain-HTTP one', () async {
    final redirect = Uri.parse('http://mirror.example/update/stable.json');
    final client = _FakeClient({
      manifestUrl.toString(): AppUpdateHttpResponse(
        statusCode: 302,
        location: redirect,
      ),
    });

    await expectLater(
      fetchAppUpdateDocument(client, manifestUrl, maxBytes: 1024),
      throwsA(isA<AppUpdateFetchException>()),
    );
    expect(client.requested, [manifestUrl]);
  });

  test('follows an HTTPS redirect that resolves to another host', () async {
    final next = Uri.parse('https://cdn.example/update/stable.json');
    final client = _FakeClient({
      manifestUrl.toString(): AppUpdateHttpResponse(
        statusCode: 302,
        location: Uri.parse('/update/next.json'),
      ),
      'https://mirror.example/update/next.json': AppUpdateHttpResponse(
        statusCode: 307,
        location: next,
      ),
      next.toString(): AppUpdateHttpResponse(
        statusCode: 200,
        body: Uint8List.fromList([9]),
      ),
    });

    final body = await fetchAppUpdateDocument(
      client,
      manifestUrl,
      maxBytes: 1024,
    );

    expect(body, [9]);
    expect(client.requested, hasLength(3));
  });

  test('stops after the redirect limit', () async {
    final steps = <String, AppUpdateHttpResponse>{};
    for (var index = 0; index < appUpdateMaxRedirects + 2; index++) {
      steps['https://mirror.example/update/$index.json'] =
          AppUpdateHttpResponse(
            statusCode: 302,
            location: Uri.parse('https://mirror.example/update/${index + 1}.json'),
          );
    }
    final client = _FakeClient(steps);

    await expectLater(
      fetchAppUpdateDocument(
        client,
        Uri.parse('https://mirror.example/update/0.json'),
        maxBytes: 1024,
      ),
      throwsA(isA<AppUpdateFetchException>()),
    );
    expect(client.requested, hasLength(appUpdateMaxRedirects + 1));
  });

  test('refuses a document larger than the limit', () async {
    final client = _FakeClient({
      manifestUrl.toString(): AppUpdateHttpResponse(
        statusCode: 200,
        body: Uint8List(9),
      ),
    });

    await expectLater(
      fetchAppUpdateDocument(client, manifestUrl, maxBytes: 8),
      throwsA(isA<AppUpdateFetchException>()),
    );
  });

  test('refuses an address without HTTPS or with credentials', () {
    expect(
      isAppUpdateHttpsUri(Uri.parse('https://mirror.example/update/stable.json')),
      isTrue,
    );
    expect(
      isAppUpdateHttpsUri(Uri.parse('http://mirror.example/update/stable.json')),
      isFalse,
    );
    expect(
      isAppUpdateHttpsUri(
        Uri.parse('https://user:pass@mirror.example/update/stable.json'),
      ),
      isFalse,
    );
    expect(
      isAppUpdateHttpsUri(
        Uri.parse('https://mirror.example:8443/update/stable.json'),
      ),
      isFalse,
    );
  });
}
