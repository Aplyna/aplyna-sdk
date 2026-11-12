part of '../aplyna.dart';

enum AplynaBillingEnvironment { sandbox, production }

enum AplynaBillingReplacementMode {
  withTimeProration,
  chargeProratedPrice,
  withoutProration,
  chargeFullPrice,
  deferred
}

class AplynaBillingProduct {
  AplynaBillingProduct.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String,
        name = json['name'] as String,
        price = json['price'] as String,
        subscriptionGroupId = json['subscriptionGroupId'] as String?,
        storeProductId = json['storeProductId'] as String?,
        basePlanId = json['basePlanId'] as String?,
        offers = List.unmodifiable((json['offers'] as List? ?? []).map((e) =>
            AplynaBillingOffer.fromJson(Map<String, dynamic>.from(e as Map))));
  final String id, name, price;
  final String? subscriptionGroupId;
  final String? storeProductId, basePlanId;
  final List<AplynaBillingOffer> offers;
}

class AplynaBillingOffer {
  AplynaBillingOffer.fromJson(Map<String, dynamic> json)
      : basePlanId = json['basePlanId'] as String,
        offerId = json['offerId'] as String?,
        offerToken = json['offerToken'] as String,
        pricingPhases = List.unmodifiable((json['pricingPhases'] as List).map(
            (e) => AplynaBillingPricingPhase.fromJson(
                Map<String, dynamic>.from(e as Map)))),
        tags = List.unmodifiable((json['tags'] as List).cast<String>());
  final String basePlanId, offerToken;
  final String? offerId;
  final List<AplynaBillingPricingPhase> pricingPhases;
  final List<String> tags;
}

class AplynaBillingPricingPhase {
  AplynaBillingPricingPhase.fromJson(Map<String, dynamic> json)
      : price = json['price'] as String,
        amountMicros = json['amountMicros'] as String,
        currency = json['currency'] as String,
        billingPeriod = json['billingPeriod'] as String,
        billingCycleCount = json['billingCycleCount'] as int,
        recurrenceMode = json['recurrenceMode'] as int;
  final String price, amountMicros, currency, billingPeriod;
  final int billingCycleCount, recurrenceMode;
}

DateTime? _billingDate(dynamic value) =>
    value == null ? null : DateTime.parse(value as String).toUtc();

class AplynaEntitlement {
  AplynaEntitlement.fromJson(Map<String, dynamic> json)
      : identifier = json['identifier'] as String,
        active = json['active'] as bool,
        productId = json['productId'] as String,
        expiresAt = _billingDate(json['expiresAt']);
  final String identifier, productId;
  final bool active;
  final DateTime? expiresAt;
}

class AplynaSubscription {
  AplynaSubscription.fromJson(Map<String, dynamic> json)
      : provider = json['provider'] as String,
        productId = json['productId'] as String,
        originalTransactionId = json['originalTransactionId'] as String,
        active = json['active'] as bool,
        status = json['status'] as String,
        expiresAt = _billingDate(json['expiresAt']),
        autoRenew = json['autoRenew'] as bool?,
        billingRetry = json['billingRetry'] as bool?,
        gracePeriodExpiresAt = _billingDate(json['gracePeriodExpiresAt']);
  final String provider, productId, originalTransactionId, status;
  final bool active;
  final bool? autoRenew, billingRetry;
  final DateTime? expiresAt, gracePeriodExpiresAt;
}

class AplynaCustomerInfo {
  AplynaCustomerInfo.fromJson(Map<String, dynamic> json)
      : customerId = json['customerId'] as String,
        environment = AplynaBillingEnvironment.values
            .byName(json['environment'] as String),
        checkedAt = DateTime.parse(json['checkedAt'] as String).toUtc(),
        entitlements = List.unmodifiable((json['entitlements'] as List).map(
            (e) => AplynaEntitlement.fromJson(
                Map<String, dynamic>.from(e as Map)))),
        subscriptions = List.unmodifiable((json['subscriptions'] as List? ?? [])
            .map((e) => AplynaSubscription.fromJson(
                Map<String, dynamic>.from(e as Map))));
  final String customerId;
  final AplynaBillingEnvironment environment;
  final DateTime checkedAt;
  final List<AplynaEntitlement> entitlements;
  final List<AplynaSubscription> subscriptions;

  /// Cancellation changes renewal intent, not the current paid access bound.
  /// Only server-granted entitlements count; cached expiry cannot grant access.
  bool hasAccessTo(String identifier, {DateTime? now}) {
    final instant = (now ?? DateTime.now()).toUtc();
    return entitlements.any((e) =>
        e.identifier == identifier &&
        e.active &&
        (e.expiresAt == null || instant.isBefore(e.expiresAt!)));
  }
}

class AplynaBillingStoreStatus {
  AplynaBillingStoreStatus.fromJson(Map<String, dynamic> json)
      : ownedByCurrentCustomer = json['ownedByCurrentCustomer'] as bool,
        productId = json['productId'] as String,
        transactionId = json['transactionId'] as String,
        state = json['state'] as String,
        willAutoRenew = json['willAutoRenew'] as bool?,
        billingRetry = json['billingRetry'] as bool?,
        source = json['source'] as String? ?? 'native_storekit',
        environment = json['environment'] as String,
        expiresAt = _billingDate(json['expiresAt']),
        gracePeriodExpiresAt = _billingDate(json['gracePeriodExpiresAt']);
  final bool ownedByCurrentCustomer;
  final bool? willAutoRenew, billingRetry;
  final String source;
  final String productId, transactionId, state, environment;
  final DateTime? expiresAt, gracePeriodExpiresAt;
}

/// Native store billing, independent of telemetry consent/configuration.
class AplynaBilling {
  const AplynaBilling._();

  Future<dynamic> _call(String method, [Map<String, dynamic> args = const {}]) {
    if (kIsWeb ||
        ![TargetPlatform.iOS, TargetPlatform.android]
            .contains(defaultTargetPlatform)) {
      throw PlatformException(
          code: 'APLYNA_BILLING_PLATFORM',
          message: 'Aplyna billing requires native iOS or Android.');
    }
    return Aplyna._invoke('billing.$method', args);
  }

  Future<void> configure({
    required String apiKey,
    required AplynaBillingEnvironment environment,
    bool sandboxOnly = true,
    bool googlePlayLicenseTester = false,
    String gatewayUrl = 'https://aplyna.com/api/billing',
  }) async {
    await _call('configure', {
      'apiKey': apiKey,
      'environment': environment.name,
      'sandboxOnly': sandboxOnly,
      'googlePlayLicenseTester': googlePlayLicenseTester,
      'gatewayUrl': gatewayUrl,
    });
  }

  Future<List<AplynaBillingProduct>> products() async =>
      List.unmodifiable((await _call('products') as List).map((e) =>
          AplynaBillingProduct.fromJson(Map<String, dynamic>.from(e as Map))));

  Future<AplynaCustomerInfo> _info(String method,
          [Map<String, dynamic> args = const {}]) async =>
      AplynaCustomerInfo.fromJson(
          Map<String, dynamic>.from(await _call(method, args) as Map));

  Future<AplynaCustomerInfo> customerInfo() => _info('customerInfo');
  Future<AplynaCustomerInfo> sync() => _info('sync');
  Future<AplynaCustomerInfo> restore() => _info('restore');
  Future<AplynaCustomerInfo> purchase(String productId,
          {String? basePlanId,
          String? offerToken,
          String? replacedProductId,
          AplynaBillingReplacementMode? replacementMode}) =>
      _info('purchase', {
        'productId': productId,
        if (basePlanId != null) 'basePlanId': basePlanId,
        if (offerToken != null) 'offerToken': offerToken,
        if (replacedProductId != null) 'replacedProductId': replacedProductId,
        if (replacementMode != null)
          'replacementMode': switch (replacementMode) {
            AplynaBillingReplacementMode.withTimeProration =>
              'with_time_proration',
            AplynaBillingReplacementMode.chargeProratedPrice =>
              'charge_prorated_price',
            AplynaBillingReplacementMode.withoutProration =>
              'without_proration',
            AplynaBillingReplacementMode.chargeFullPrice => 'charge_full_price',
            AplynaBillingReplacementMode.deferred => 'deferred'
          }
      });

  /// Opens the platform's subscription management; cancellation retains paid access.
  Future<void> manageSubscriptions({String? productId}) async {
    await _call(
        'manageSubscriptions', {if (productId != null) 'productId': productId});
  }

  /// Separately labelled native state; does not itself grant server access.
  Future<List<AplynaBillingStoreStatus>> storeStatuses() async =>
      List.unmodifiable((await _call('storeStatuses') as List).map((e) =>
          AplynaBillingStoreStatus.fromJson(
              Map<String, dynamic>.from(e as Map))));

  /// iOS Sandbox-only request; Android returns APLYNA_BILLING_UNSUPPORTED.
  /// Submission is not a confirmed refund/revocation.
  Future<String> requestRefund(String productId, String transactionId) async =>
      (await _call('requestRefund', {
        'productId': productId,
        'transactionId': transactionId,
      }) as Map)['status'] as String;

  Future<String?> updateError() async =>
      (await _call('diagnostics') as Map)['updateError'] as String?;
}
