import 'package:flclashx/product/android/android_package_installer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app');
  const installer = MethodChannelAndroidPackageInstaller();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('uses the dedicated Android package install method', () async {
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      receivedCall = call;
      return true;
    });

    final accepted = await installer.install('/data/user/0/app/update.apk');

    expect(accepted, isTrue);
    expect(receivedCall?.method, 'installPackage');
    expect(
      receivedCall?.arguments,
      {'path': '/data/user/0/app/update.apk'},
    );
  });

  test('treats an empty native result as a rejected handoff', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);

    expect(await installer.install('/tmp/update.apk'), isFalse);
  });
}
