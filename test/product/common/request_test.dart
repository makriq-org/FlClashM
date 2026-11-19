import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flclashx/common/request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Response<String> response(int? statusCode) => Response(
        requestOptions: RequestOptions(path: 'https://example.com/profile'),
        statusCode: statusCode,
        data: 'response body',
      );

  test('tunnel HTTP transport accepts successful final responses', () {
    final successfulResponse = response(204);

    expect(validateTunnelHttpResponse(successfulResponse), successfulResponse);
  });

  test('tunnel HTTP transport rejects error responses with their payload', () {
    final errorResponse = response(401);

    expect(
      () => validateTunnelHttpResponse(errorResponse),
      throwsA(
        isA<DioException>()
            .having((error) => error.type, 'type', DioExceptionType.badResponse)
            .having((error) => error.response, 'response', errorResponse),
      ),
    );

    for (final statusCode in <int?>[null, 302, 500]) {
      expect(
        () => validateTunnelHttpResponse(response(statusCode)),
        throwsA(isA<DioException>()),
      );
    }
  });

  test('tunnel HTTP transport rejects a partial response', () {
    expect(
      () => validateTunnelHttpResponse(response(HttpStatus.partialContent)),
      throwsA(isA<DioException>()),
    );
  });

  test('a direct download accepts only a whole final response', () {
    final accepts = tunnelDownloadOptions.validateStatus!;

    for (final statusCode in <int>[200, 204, 299]) {
      expect(accepts(statusCode), isTrue, reason: 'HTTP $statusCode');
    }
    // dio treats every 2xx as a success, so a 206 has to be named here.
    for (final statusCode in <int?>[
      null,
      199,
      HttpStatus.partialContent,
      300,
      404,
      500,
    ]) {
      expect(accepts(statusCode), isFalse, reason: 'HTTP $statusCode');
    }
  });

  group('decompressUnlabeled', () {
    test('inflates a body nothing labelled and passes a plain one through', () {
      final yaml = Uint8List.fromList(utf8.encode('proxies: []\n'));

      expect(decompressUnlabeled(yaml), same(yaml));
      expect(decompressUnlabeled(Uint8List.fromList(gzip.encode(yaml))), yaml);
    });

    test('leaves a body that claims compression but is broken', () {
      final broken = Uint8List.fromList([0x1f, 0x8b, 0x08, 0x00]);

      expect(decompressUnlabeled(broken), same(broken));
    });

    test('gives up once the output passes the limit', () {
      final body = Uint8List.fromList(gzip.encode(Uint8List(4096)));

      expect(decompressUnlabeled(body, limit: 4096), hasLength(4096));
      expect(decompressUnlabeled(body, limit: 4095), isNull);
    });
  });
}
