import 'dart:convert';
import 'package:aplyna/aplyna.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aplyna/sdk');
  final calls = <Map<String, dynamic>>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      calls.add({
        'method': args['method'],
        'args': jsonDecode(args['argumentsJSON'] as String)
      });
      return jsonEncode(switch (args['method']) {
        'configure' => {'installationId': 'stable-id'},
        'assignment' => {
            'flowId': 'flow_1',
            'experimentId': 'exp_1',
            'variant': 'B'
          },
        'pendingEventCount' => 2,
        'configuration' => {'schema_version': 1, 'steps': []},
        _ => null,
      });
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  test('configure preserves explicit consent and assignment is not an exposure',
      () async {
    expect(await Aplyna.configure(apiKey: 'public-sdk-key'), 'stable-id');
    expect(calls.map((call) => call['method']), ['configure']);
    final assignment = await Aplyna.assignment('flow_1');
    expect(assignment.variant, 'B');
    expect(calls.any((call) => call['method'] == 'expose'), isFalse);
    await Aplyna.setConsent(true);
    await Aplyna.setAppLanguage('fr');
    expect(calls.last, {
      'method': 'setAppLanguage',
      'args': {'language': 'fr'}
    });
    await Aplyna.refreshTrackingAuthorizationStatus();
    expect(calls.last,
        {'method': 'refreshTrackingAuthorizationStatus', 'args': {}});
    await Aplyna.track('onboarding_step_viewed',
        flowId: 'flow_1',
        stepId: 'welcome',
        assignment: assignment,
        properties: {'screen': 'welcome'});
    expect((calls.last['args'] as Map)['assignment'], assignment.toJson());
    await Aplyna.expose(assignment);
    expect(await Aplyna.pendingEventCount(), 2);
    expect((await Aplyna.configuration('flow_1'))['schema_version'], 1);
    await Aplyna.flush();
    await Aplyna.setConsent(false);
    expect(calls.last['args'], {'granted': false});
  });
  test('native errors remain errors at the Flutter boundary', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
          code: 'APLYNA_HTTP_401', message: 'SDK key revoked');
    });
    await expectLater(Aplyna.flush(), throwsA(isA<PlatformException>()));
  });
}
