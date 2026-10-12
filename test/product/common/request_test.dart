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
}
