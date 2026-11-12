import 'dart:convert';
import 'package:aplyna/aplyna.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> entitlement({bool active = true}) => {
      'identifier': 'premium',
      'isActive': active,
      'willRenew': active,
      'periodType': 'TRIAL',
      'latestPurchaseDate': null,
      'originalPurchaseDate': null,
      'expirationDate': '2099-01-01T00:00:00.000Z',
      'store': 'APP_STORE',
      'productIdentifier': 'monthly',
      'isSandbox': true,
      'unsubscribeDetectedAt': null,
      'billingIssueDetectedAt': null,
      'ownershipType': 'PURCHASED',
    };

Map<String, dynamic> customerInfo({bool active = true}) => {
      'entitlements': {
        'all': {'premium': entitlement(active: active)},
        'active': active ? {'premium': entitlement()} : <String, dynamic>{},
      },
      'activeSubscriptions': active ? ['monthly'] : <String>[],
      'allPurchasedProductIdentifiers': ['monthly'],
      'latestExpirationDate': '2099-01-01T00:00:00.000Z',
      'originalAppUserId': 'user_1',
      'requestDate': '2026-11-12T11:59:00.000Z',
      'managementURL': 'https://apps.apple.com/account/subscriptions',
      'allExpirationDates': {'monthly': '2099-01-01T00:00:00.000Z'},
    };

Map<String, dynamic> package(String identifier, String type, String product) => {
      'identifier': identifier,
      'packageType': type,
      'offeringIdentifier': 'default',
      'presentedOfferingContext': {'offeringIdentifier': 'default'},
      'product': {
        'identifier': product,
        'title': 'Premium',
        'description': '',
        'price': 9.99,
        'priceString': '9,99 €',
        'currencyCode': 'EUR',
        'productCategory': 'SUBSCRIPTION',
        'subscriptionPeriod': 'P1M',
        'introPrice': {
          'price': 0,
          'priceString': 'Free',
          'period': 'P1W',
          'cycles': 1,
          'periodUnit': 'WEEK',
          'periodNumberOfUnits': 1
        },
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aplyna/sdk');
  final calls = <Map<String, dynamic>>[];
  Object? Function(String method, Map<String, dynamic> args)? respond;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    respond = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final raw = Map<String, dynamic>.from(call.arguments as Map);
      final method = raw['method'] as String;
      final args =
          Map<String, dynamic>.from(jsonDecode(raw['argumentsJSON'] as String));
      calls.add({'method': method, 'args': args});
      return jsonEncode(respond?.call(method, args));
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('configure and identity use the RevenueCat call names', () async {
    respond = (method, _) => switch (method) {
          'purchases.getAppUserID' => {'appUserID': 'user_1', 'isAnonymous': false},
          'purchases.logIn' => {'customerInfo': customerInfo(), 'created': true},
          'purchases.logOut' => customerInfo(active: false),
          _ => null,
        };
    await Purchases.configure(
        PurchasesConfiguration('aplyna_ios_key')..appUserID = 'user_1');
    expect(calls.single, {
      'method': 'purchases.configure',
      'args': {'apiKey': 'aplyna_ios_key', 'appUserID': 'user_1'}
    });
    expect(await Purchases.appUserID, 'user_1');
    expect(await Purchases.isAnonymous, isFalse);
    final login = await Purchases.logIn('user_2');
    expect(login.created, isTrue);
    expect(login.customerInfo.entitlements.active.containsKey('premium'), isTrue);
    expect(calls.last['args'], {'appUserID': 'user_2'});
    final out = await Purchases.logOut();
    expect(out.entitlements.active, isEmpty);
  });

  test('offerings decode packages, products and the current offering', () async {
    final monthly = package(r'$rc_monthly', 'MONTHLY', 'monthly');
    final annual = package(r'$rc_annual', 'ANNUAL', 'annual');
    final offering = {
      'identifier': 'default',
      'serverDescription': 'Standard',
      'metadata': <String, dynamic>{},
      'availablePackages': [monthly, annual],
      'monthly': monthly,
      'annual': annual,
    };
    respond = (_, __) => {
          'all': {'default': offering},
          'current': offering
        };
    final offerings = await Purchases.getOfferings();
    final current = offerings.current!;
    expect(current.identifier, 'default');
    expect(current.serverDescription, 'Standard');
    expect(current.availablePackages.length, 2);
    expect(current.monthly!.packageType, PackageType.monthly);
    expect(current.monthly!.storeProduct.priceString, '9,99 €');
    expect(current.monthly!.storeProduct.price, 9.99);
    expect(current.monthly!.storeProduct.subscriptionPeriod, 'P1M');
    expect(current.monthly!.storeProduct.introductoryPrice!.periodUnit,
        PeriodUnit.week);
    expect(current.monthly!.offeringIdentifier, 'default');
    expect(current.annual!.identifier, r'$rc_annual');
    expect(current.weekly, isNull);
    expect(current.getPackage(r'$rc_annual')!.storeProduct.identifier, 'annual');
    expect(offerings.getOffering('default'), isNotNull);
    expect(offerings.getOffering('missing'), isNull);

    respond = (_, __) => {'all': <String, dynamic>{}, 'current': null};
    final empty = await Purchases.getOfferings();
    expect(empty.current, isNull);
    expect(empty.all, isEmpty);
  });

  test('a purchase returns customer info and notifies listeners once per change',
      () async {
    final seen = <CustomerInfo>[];
    void listener(CustomerInfo info) => seen.add(info);
    Purchases.addCustomerInfoUpdateListener(listener);
    respond = (method, _) => switch (method) {
          'purchases.purchaseProduct' => {
              'customerInfo': customerInfo(),
              'productIdentifier': 'monthly',
              'transaction': {
                'transactionIdentifier': '2000001',
                'productIdentifier': 'monthly',
                'purchaseDate': '2026-11-12T12:00:00.000Z'
              }
            },
          _ => customerInfo(),
        };
    await Purchases.configure(PurchasesConfiguration('aplyna_ios_key'));
    final offeringPackage =
        Package.fromJson(package(r'$rc_monthly', 'MONTHLY', 'monthly'));
    final result = await Purchases.purchasePackage(offeringPackage);
    expect(calls.last, {
      'method': 'purchases.purchaseProduct',
      'args': {'productIdentifier': 'monthly'}
    });
    expect(result.productIdentifier, 'monthly');
    expect(result.storeTransaction!.transactionIdentifier, '2000001');
    final premium = result.customerInfo.entitlements.all['premium']!;
    expect(premium.isActive, isTrue);
    expect(premium.periodType, PeriodType.trial);
    expect(premium.store, Store.appStore);
    expect(premium.ownershipType, OwnershipType.purchased);
    expect(result.customerInfo.activeSubscriptions, ['monthly']);
    expect(result.customerInfo.allExpirationDates['monthly'],
        '2099-01-01T00:00:00.000Z');
    // Same state again: no second notification. A change notifies again.
    await Purchases.getCustomerInfo();
    await Purchases.restorePurchases();
    expect(seen.length, 1);
    respond = (_, __) => customerInfo(active: false);
    await Purchases.getCustomerInfo();
    expect(seen.length, 2);
    expect(seen.last.entitlements.active, isEmpty);
    Purchases.removeCustomerInfoUpdateListener(listener);
    respond = (_, __) => customerInfo();
    await Purchases.getCustomerInfo();
    expect(seen.length, 2);
  });

  test('cancelled, pending, offline and in-progress errors keep their codes',
      () async {
    Future<PlatformException> failWith(String code,
        [Map<String, dynamic>? details]) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: code, message: 'native', details: details);
      });
      try {
        await Purchases.purchaseStoreProduct(StoreProduct.fromJson(
            Map<String, dynamic>.from(
                package('p', 'CUSTOM', 'monthly')['product'] as Map)));
      } on PlatformException catch (error) {
        return error;
      }
      fail('expected a PlatformException');
    }

    final cancelled = await failWith('1', {'userCancelled': true});
    expect(PurchasesErrorHelper.getErrorCode(cancelled),
        PurchasesErrorCode.purchaseCancelledError);
    expect((cancelled.details as Map)['userCancelled'], isTrue);
    expect(PurchasesErrorHelper.getErrorCode(await failWith('20')),
        PurchasesErrorCode.paymentPendingError);
    expect(PurchasesErrorHelper.getErrorCode(await failWith('35')),
        PurchasesErrorCode.offlineConnectionError);
    expect(PurchasesErrorHelper.getErrorCode(await failWith('15')),
        PurchasesErrorCode.operationAlreadyInProgressError);
    expect(PurchasesErrorHelper.getErrorCode(await failWith('7')),
        PurchasesErrorCode.receiptAlreadyInUseError);
    expect(PurchasesErrorHelper.getErrorCode(await failWith('APLYNA_SDK')),
        PurchasesErrorCode.unknownError);
    expect(PurchasesErrorHelper.getErrorCode(await failWith('999')),
        PurchasesErrorCode.unknownError);
  });

  test('error code numbers match purchases_flutter', () {
    expect(PurchasesErrorCode.purchaseCancelledError.index, 1);
    expect(PurchasesErrorCode.networkError.index, 10);
    expect(PurchasesErrorCode.invalidAppUserIdError.index, 14);
    expect(PurchasesErrorCode.paymentPendingError.index, 20);
    expect(PurchasesErrorCode.logOutWithAnonymousUserError.index, 22);
    expect(PurchasesErrorCode.configurationError.index, 23);
    expect(PurchasesErrorCode.customerInfoError.index, 29);
    expect(PurchasesErrorCode.offlineConnectionError.index, 35);
  });

  test('attributes use the reserved keys and allow deletion', () async {
    await Purchases.setAttributes({'plan': 'gold', 'old': null});
    expect(calls.last, {
      'method': 'purchases.setAttributes',
      'args': {
        'attributes': {'plan': 'gold', 'old': null}
      }
    });
    await Purchases.setEmail('a@example.com');
    expect(calls.last['args'], {
      'attributes': {r'$email': 'a@example.com'}
    });
    await Purchases.setDisplayName(null);
    expect(calls.last['args'], {
      'attributes': {r'$displayName': null}
    });
    await Purchases.setPushToken('token');
    expect(calls.last['args'], {
      'attributes': {r'$apnsTokens': 'token'}
    });
  });

  test('unsupported platforms fail with the unsupported error code', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await Purchases.getOfferings();
      fail('expected a PlatformException');
    } on PlatformException catch (error) {
      expect(PurchasesErrorHelper.getErrorCode(error),
          PurchasesErrorCode.unsupportedError);
    }
  });
}
