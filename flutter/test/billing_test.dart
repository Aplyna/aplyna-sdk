import 'dart:convert';
import 'package:aplyna/aplyna.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> info(
        {bool granted = true,
        bool renews = false,
        String status = 'active',
        String expiry = '2026-11-10T15:00:00Z'}) =>
    {
      'customerId': 'customer',
      'environment': 'sandbox',
      'checkedAt': '2026-11-10T14:00:00Z',
      'entitlements': [
        if (granted)
          {
            'identifier': 'premium',
            'active': true,
            'productId': 'monthly',
            'expiresAt': expiry,
          }
      ],
      'subscriptions': [
        {
          'provider': 'apple',
          'productId': 'monthly',
          'originalTransactionId': '2000000000000001',
          'active': granted,
          'status': status,
          'expiresAt': expiry,
          'autoRenew': renews,
          'billingRetry': status == 'grace_period' || status == 'billing_retry',
          'gracePeriodExpiresAt': status == 'grace_period' ? expiry : null,
        }
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aplyna/sdk');
  final calls = <Map<String, dynamic>>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      calls.add({
        'method': args['method'],
        'args': jsonDecode(args['argumentsJSON'] as String)
      });
      return jsonEncode(switch (args['method']) {
        'billing.configure' => {'environment': 'sandbox'},
        'billing.products' => [
            {
              'id': 'monthly',
              'name': 'Premium',
              'price': '€9.99',
              'subscriptionGroupId': 'group'
            }
          ],
        'billing.manageSubscriptions' => null,
        'billing.requestRefund' => {'status': 'success'},
        'billing.diagnostics' => {'updateError': null},
        'billing.storeStatuses' => [
            {
              'ownedByCurrentCustomer': true,
              'productId': 'monthly',
              'transactionId': '2000000000000001',
              'state': 'subscribed',
              'willAutoRenew': false,
              'billingRetry': false,
              'environment': 'sandbox',
              'expiresAt': '2026-11-10T15:00:00Z',
              'gracePeriodExpiresAt': null,
            }
          ],
        _ => info(),
      });
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('cancelled renewal retains verified paid access only before expiry', () {
    final value = AplynaCustomerInfo.fromJson(info());
    expect(value.subscriptions.single.autoRenew, isFalse);
    expect(value.hasAccessTo('premium', now: DateTime.utc(2026, 11, 10, 14)),
        isTrue);
    expect(value.hasAccessTo('premium', now: DateTime.utc(2026, 11, 10, 15)),
        isFalse);
    expect(value.hasAccessTo('different', now: DateTime.utc(2026, 11, 10, 14)),
        isFalse);
  });
  test('grace grants only the signed bound and retry alone grants nothing', () {
    final grace = AplynaCustomerInfo.fromJson(info(status: 'grace_period'));
    expect(grace.subscriptions.single.billingRetry, isTrue);
    expect(grace.hasAccessTo('premium', now: DateTime.utc(2026, 11, 10, 14)),
        isTrue);
    expect(grace.hasAccessTo('premium', now: DateTime.utc(2026, 11, 10, 15)),
        isFalse);
    for (final state in ['billing_retry', 'revoked', 'expired']) {
      final value =
          AplynaCustomerInfo.fromJson(info(granted: false, status: state));
      expect(value.hasAccessTo('premium', now: DateTime.utc(2026, 11, 10, 14)),
          isFalse);
    }
  });
  test('malformed paid expiry cannot become unlimited access', () {
    expect(() => AplynaCustomerInfo.fromJson(info(expiry: 'invalid')),
        throwsFormatException);
  });
  test(
      'billing config is separate from analytics and defaults to sandbox guard',
      () async {
    await Aplyna.billing.configure(
        apiKey: 'aplyna_ios_test',
        environment: AplynaBillingEnvironment.sandbox);
    expect(calls.single, {
      'method': 'billing.configure',
      'args': {
        'apiKey': 'aplyna_ios_test',
        'environment': 'sandbox',
        'sandboxOnly': true,
        'googlePlayLicenseTester': false,
        'gatewayUrl': 'https://aplyna.com/api/billing',
      }
    });
    expect((await Aplyna.billing.products()).single.id, 'monthly');
    for (final value in [
      await Aplyna.billing.customerInfo(),
      await Aplyna.billing.sync(),
      await Aplyna.billing.restore(),
      await Aplyna.billing.purchase('monthly')
    ]) {
      expect(value.customerId, 'customer');
    }
    expect(calls.last, {
      'method': 'billing.purchase',
      'args': {'productId': 'monthly'}
    });
    await Aplyna.billing.manageSubscriptions();
    expect(
        (await Aplyna.billing.storeStatuses()).single.willAutoRenew, isFalse);
    expect(await Aplyna.billing.requestRefund('monthly', '2000000000000001'),
        'success');
    expect(calls.last['args'],
        {'productId': 'monthly', 'transactionId': '2000000000000001'});
    expect(await Aplyna.billing.updateError(), isNull);
    expect(calls.every((c) => (c['method'] as String).startsWith('billing.')),
        isTrue);
  });
  test(
      'native cancellation, pending, ownership and HTTP errors retain their codes',
      () async {
    for (final code in [
      'APLYNA_BILLING_CANCELLED',
      'APLYNA_BILLING_PENDING',
      'APLYNA_BILLING_CUSTOMER_CONFLICT',
      'APLYNA_BILLING_HTTP_503'
    ]) {
      messenger.setMockMethodCallHandler(
          channel, (_) async => throw PlatformException(code: code));
      await expectLater(
          Aplyna.billing.purchase('monthly'),
          throwsA(
              isA<PlatformException>().having((e) => e.code, 'code', code)));
    }
  });
  test('unsupported desktop billing fails before calling native', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await expectLater(
        Aplyna.billing.configure(
            apiKey: 'aplyna_ios_test',
            environment: AplynaBillingEnvironment.sandbox),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'APLYNA_BILLING_PLATFORM')));
    expect(calls, isEmpty);
  });
  test(
      'Android routes explicit tester setup and plan replacement to native billing',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await Aplyna.billing.configure(
        apiKey: 'aplyna_android_test',
        environment: AplynaBillingEnvironment.sandbox,
        googlePlayLicenseTester: true);
    expect(calls.single['args'], containsPair('googlePlayLicenseTester', true));
    await Aplyna.billing.purchase('subscription:monthly',
        basePlanId: 'monthly',
        offerToken: 'eligible_offer',
        replacedProductId: 'subscription:weekly',
        replacementMode: AplynaBillingReplacementMode.withTimeProration);
    expect(calls.last, {
      'method': 'billing.purchase',
      'args': {
        'productId': 'subscription:monthly',
        'basePlanId': 'monthly',
        'offerToken': 'eligible_offer',
        'replacedProductId': 'subscription:weekly',
        'replacementMode': 'with_time_proration'
      }
    });
    await Aplyna.billing.manageSubscriptions(productId: 'subscription:monthly');
    expect(calls.last['args'], {'productId': 'subscription:monthly'});
  });
  test('Google offer pricing and unknown server state stay explicit', () {
    final product = AplynaBillingProduct.fromJson({
      'id': 'subscription:monthly',
      'name': 'Premium',
      'price': '€9.99',
      'subscriptionGroupId': null,
      'storeProductId': 'subscription',
      'basePlanId': 'monthly',
      'offers': [
        {
          'basePlanId': 'monthly',
          'offerId': 'trial',
          'offerToken': 'eligible_offer',
          'tags': ['intro'],
          'pricingPhases': [
            {
              'price': 'Free',
              'amountMicros': '0',
              'currency': 'EUR',
              'billingPeriod': 'P3D',
              'billingCycleCount': 1,
              'recurrenceMode': 2
            },
            {
              'price': '€9.99',
              'amountMicros': '9990000',
              'currency': 'EUR',
              'billingPeriod': 'P1M',
              'billingCycleCount': 0,
              'recurrenceMode': 1
            }
          ]
        }
      ]
    });
    expect(product.basePlanId, 'monthly');
    expect(product.offers.single.offerId, 'trial');
    expect(product.offers.single.pricingPhases.last.amountMicros, '9990000');
    final status = AplynaBillingStoreStatus.fromJson({
      'ownedByCurrentCustomer': true,
      'productId': 'subscription:monthly',
      'transactionId': 'snapshot:token_hash',
      'state': 'inactive',
      'willAutoRenew': null,
      'billingRetry': null,
      'source': 'server_verified_google',
      'environment': 'sandbox',
      'expiresAt': null,
      'gracePeriodExpiresAt': null
    });
    expect(status.source, 'server_verified_google');
    expect(status.billingRetry, isNull);
    expect(status.willAutoRenew, isNull);
  });
}
