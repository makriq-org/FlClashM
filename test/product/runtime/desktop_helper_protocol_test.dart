import 'dart:async';

import 'package:flclashx/product/runtime/desktop_helper_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DesktopHelperProtocol', () {
    test('accepts only the fixed install identity and bundled artifacts', () {
      expect(
        DesktopHelperProtocol.validate(
          const DesktopHelperRequest(
            operation: DesktopHelperOperation.runtimeStart,
            runtimeArtifact: 'mihomo',
            parameters: {'runtimeToken': 'runtime_token_1234'},
          ),
        ),
        isNull,
      );
      expect(
        DesktopHelperProtocol.validate(
          const DesktopHelperRequest(
            operation: DesktopHelperOperation.runtimeStart,
            runtimeArtifact: '/tmp/evil',
            parameters: {'runtimeToken': 'runtime_token_1234'},
          ),
        ),
        isNotNull,
      );
      expect(
        DesktopHelperProtocol.validate(
          const DesktopHelperRequest(
            operation: DesktopHelperOperation.tunOpen,
            parameters: {'command': 'sh -c id'},
          ),
        ),
        isNotNull,
      );
    });

    test('requires operation-specific parameter types and formats', () {
      expect(
        DesktopHelperProtocol.validate(
          const DesktopHelperRequest(
            operation: DesktopHelperOperation.tunOpen,
            parameters: {'interface': 'flclashm0', 'mtu': 1500},
          ),
        ),
        isNull,
      );
      expect(
        DesktopHelperProtocol.validate(
          const DesktopHelperRequest(
            operation: DesktopHelperOperation.tunOpen,
            parameters: {'interface': 'flclashm0'},
          ),
        ),
        isNotNull,
      );
      expect(
        DesktopHelperProtocol.validate(
          const DesktopHelperRequest(
            operation: DesktopHelperOperation.routeApply,
            parameters: {
              'interface': 'tun0',
              'routes': ['not-a-route'],
            },
          ),
        ),
        isNotNull,
      );
      expect(
        DesktopHelperProtocol.validate(
          const DesktopHelperRequest(
            operation: DesktopHelperOperation.dnsApply,
            parameters: {
              'interface': 'tun0',
              'servers': ['dns.example'],
            },
          ),
        ),
        isNotNull,
      );
      expect(
        DesktopHelperProtocol.validate(
          const DesktopHelperRequest(
            operation: DesktopHelperOperation.runtimeStop,
            runtimeArtifact: 'mihomo',
            parameters: {'runtimeToken': 'short'},
          ),
        ),
        isNotNull,
      );
    });

    test('rejects protocol downgrade and unexpected identity', () {
      expect(
        DesktopHelperProtocol.validate(
          const DesktopHelperRequest(
            protocolVersion: 0,
            operation: DesktopHelperOperation.tunClose,
            parameters: {'interface': 'tun0'},
          ),
        ),
        contains('version'),
      );
      expect(
        DesktopHelperProtocol.validate(
          const DesktopHelperRequest(
            installIdentity: 'other.app',
            operation: DesktopHelperOperation.tunClose,
            parameters: {'interface': 'tun0'},
          ),
        ),
        contains('identity'),
      );
    });

    test('serializes the closed helper request and response vocabulary', () {
      const request = DesktopHelperRequest(
        operation: DesktopHelperOperation.runtimeStart,
        runtimeArtifact: 'mihomo',
        parameters: {'runtimeToken': 'runtime_token_1234'},
      );
      expect(WindowsDesktopHelperMessageCodec.encode(request), isNotEmpty);
      final response = WindowsDesktopHelperMessageCodec.decode(const [
        123,
        34,
        115,
        116,
        97,
        116,
        101,
        34,
        58,
        34,
        114,
        101,
        97,
        100,
        121,
        34,
        44,
        34,
        109,
        101,
        115,
        115,
        97,
        103,
        101,
        34,
        58,
        34,
        34,
        125,
      ]);
      expect(response.isSuccess, isTrue);
    });

    test('times out and invokes the declared rollback operation', () async {
      final transport = _Transport();
      final client = DesktopHelperClient(
        transport: transport,
        timeout: const Duration(milliseconds: 10),
      );
      final response = await client.execute(
        const DesktopHelperRequest(
          operation: DesktopHelperOperation.routeApply,
          parameters: {
            'interface': 'tun0',
            'routes': ['0.0.0.0/0'],
          },
        ),
        rollback: const DesktopHelperRequest(
          operation: DesktopHelperOperation.routeRollback,
          parameters: {'transaction': 'route-1'},
        ),
      );

      expect(response.isSuccess, isFalse);
      expect(transport.operations, [
        DesktopHelperOperation.routeApply,
        DesktopHelperOperation.routeRollback,
      ]);
    });
  });
}

class _Transport implements DesktopHelperTransport {
  final operations = <DesktopHelperOperation>[];

  @override
  Future<DesktopHelperResponse> send(DesktopHelperRequest request) async {
    operations.add(request.operation);
    if (request.operation == DesktopHelperOperation.routeApply) {
      await Completer<void>().future;
    }
    return const DesktopHelperResponse(state: DesktopHelperState.ready);
  }
}
