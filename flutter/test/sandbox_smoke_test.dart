import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:aplyna/aplyna.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aplyna/sdk');
  final env = Platform.environment;
  test('Dart channel / Swift bridge delivers real local sandbox events',
      () async {
    final base = env['APLYNA_SDK_SMOKE_URL']!;
    final key = env['APLYNA_SDK_SMOKE_KEY']!;
    expect(['127.0.0.1', 'localhost', '::1'], contains(Uri.parse(base).host));
    expect(key.startsWith('aplyna_test_'), isTrue);
    final process =
        await Process.start(env['APLYNA_SDK_SMOKE_BRIDGE']!, ['bridge']);
    final pending = <int, Completer<String>>{};
    var sequence = 0;
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final response = jsonDecode(line) as Map<String, dynamic>;
      final waiting = pending.remove(response['id']);
      if (response.containsKey('error')) {
        waiting?.completeError(PlatformException(
            code: 'NATIVE_SMOKE', message: response['error'] as String));
      } else {
        waiting?.complete(response['result'] as String);
      }
    });
    final errors = process.stderr.drain<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final id = ++sequence;
      final waiting = Completer<String>();
      pending[id] = waiting;
      process.stdin.writeln(jsonEncode({'id': id, ...args}));
      return waiting.future.timeout(const Duration(seconds: 20));
    });
    try {
      expect(
          await Aplyna.configure(
              apiKey: key,
              baseUrl: base,
              installationId: 'sdk_flutter_bridge_sandbox'),
          'sdk_flutter_bridge_sandbox');
      await expectLater(
          Aplyna.track('app_opened'), throwsA(isA<PlatformException>()));
      await Aplyna.setConsent(true);
      for (final name in [
        'app_opened',
        'onboarding_completed',
        'trial_started'
      ]) {
        await Aplyna.track(name, properties: {
          'verification': 'local_sdk_test',
          'runtime': 'flutter_swift_bridge'
        });
      }
      await Aplyna.flush();
      expect(await Aplyna.pendingEventCount(), 0);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
      await output.cancel();
      await errors;
    }
  },
      skip: env['APLYNA_SDK_SMOKE_BRIDGE'] == null
          ? 'Set explicit local sandbox smoke variables to run; this does not launch a native Flutter host.'
          : false);
}
