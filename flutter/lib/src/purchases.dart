part of '../aplyna.dart';

// Aplyna's purchase API uses the same names and shapes as RevenueCat's purchases_flutter so
// an app can switch by changing its import and API key. Independent implementation; it talks
// only to the Aplyna billing gateway.

/// Same order and numeric values as purchases_flutter's `PurchasesErrorCode`.
enum PurchasesErrorCode {
  unknownError,
  purchaseCancelledError,
  storeProblemError,
  purchaseNotAllowedError,
  purchaseInvalidError,
  productNotAvailableForPurchaseError,
  productAlreadyPurchasedError,
  receiptAlreadyInUseError,
  invalidReceiptError,
  missingReceiptFileError,
  networkError,
  invalidCredentialsError,
  unexpectedBackendResponseError,
  receiptInUseByOtherSubscriberError,
  invalidAppUserIdError,
  operationAlreadyInProgressError,
  unknownBackendError,
  invalidAppleSubscriptionKeyError,
  ineligibleError,
  insufficientPermissionsError,
  paymentPendingError,
  invalidSubscriberAttributesError,
  logOutWithAnonymousUserError,
  configurationError,
  unsupportedError,
  emptySubscriberAttributesError,
  productDiscountMissingIdentifierError,
  unknownNonNativeError,
  productDiscountMissingSubscriptionGroupIdentifierError,
  customerInfoError,
  systemInfoError,
  beginRefundRequestError,
  productRequestTimeout,
  apiEndpointBlocked,
  invalidPromotionalOfferError,
  offlineConnectionError,
}

class PurchasesErrorHelper {
  /// Reads the error code of a `PlatformException` thrown by [Purchases].
  static PurchasesErrorCode getErrorCode(PlatformException e) {
    final code = int.tryParse(e.code);
    if (code == null || code < 0 || code >= PurchasesErrorCode.values.length) {
      return PurchasesErrorCode.unknownError;
    }
    return PurchasesErrorCode.values[code];
  }
}

enum PackageType {
  unknown,
  custom,
  lifetime,
  annual,
  sixMonth,
  threeMonth,
  twoMonth,
  monthly,
  weekly
}

enum PeriodType { normal, intro, trial, prepaid, unknown }

enum Store {
  appStore,
  macAppStore,
  playStore,
  stripe,
  promotional,
  unknownStore,
  amazon
}

enum OwnershipType { purchased, familyShared, unknown }

enum ProductCategory { subscription, nonSubscription }

enum LogLevel { verbose, debug, info, warn, error }

T _named<T extends Enum>(List<T> values, dynamic raw, T fallback) {
  final wanted = (raw as String? ?? '').replaceAll('_', '').toLowerCase();
  return values.firstWhere((v) => v.name.toLowerCase() == wanted,
      orElse: () => fallback);
}

Map<String, dynamic> _map(dynamic value) =>
    Map<String, dynamic>.from(value as Map);

class EntitlementInfo {
  EntitlementInfo.fromJson(Map<String, dynamic> json)
      : identifier = json['identifier'] as String,
        isActive = json['isActive'] as bool,
        willRenew = json['willRenew'] as bool,
        latestPurchaseDate = json['latestPurchaseDate'] as String?,
        originalPurchaseDate = json['originalPurchaseDate'] as String?,
        productIdentifier = json['productIdentifier'] as String,
        productPlanIdentifier = json['productPlanIdentifier'] as String?,
        isSandbox = json['isSandbox'] as bool,
        ownershipType = _named(
            OwnershipType.values, json['ownershipType'], OwnershipType.unknown),
        store = _named(Store.values, json['store'], Store.unknownStore),
        periodType =
            _named(PeriodType.values, json['periodType'], PeriodType.unknown),
        expirationDate = json['expirationDate'] as String?,
        unsubscribeDetectedAt = json['unsubscribeDetectedAt'] as String?,
        billingIssueDetectedAt = json['billingIssueDetectedAt'] as String?;
  final String identifier, productIdentifier;
  final bool isActive, willRenew, isSandbox;
  final String? latestPurchaseDate, originalPurchaseDate, productPlanIdentifier;
  final OwnershipType ownershipType;
  final Store store;
  final PeriodType periodType;

  /// ISO 8601; null for access that does not expire.
  final String? expirationDate;
  final String? unsubscribeDetectedAt, billingIssueDetectedAt;
}

class EntitlementInfos {
  EntitlementInfos.fromJson(Map<String, dynamic> json)
      : all = Map.unmodifiable(_map(json['all'])
            .map((k, v) => MapEntry(k, EntitlementInfo.fromJson(_map(v))))),
        active = Map.unmodifiable(_map(json['active'])
            .map((k, v) => MapEntry(k, EntitlementInfo.fromJson(_map(v)))));
  final Map<String, EntitlementInfo> all, active;
}

class CustomerInfo {
  CustomerInfo.fromJson(Map<String, dynamic> json)
      : entitlements = EntitlementInfos.fromJson(_map(json['entitlements'])),
        latestExpirationDate = json['latestExpirationDate'] as String?,
        allExpirationDates = Map.unmodifiable(
            _map(json['allExpirationDates'] ?? const {})
                .map((k, v) => MapEntry(k, v as String?))),
        activeSubscriptions =
            List.unmodifiable((json['activeSubscriptions'] as List).cast<String>()),
        allPurchasedProductIdentifiers = List.unmodifiable(
            (json['allPurchasedProductIdentifiers'] as List).cast<String>()),
        originalAppUserId = json['originalAppUserId'] as String,
        requestDate = json['requestDate'] as String,
        managementURL = json['managementURL'] as String?,
        _signature = jsonEncode([
          json['entitlements'],
          json['activeSubscriptions'],
          json['allExpirationDates'],
          json['originalAppUserId']
        ]);
  final EntitlementInfos entitlements;
  final String? latestExpirationDate;
  final Map<String, String?> allExpirationDates;
  final List<String> activeSubscriptions, allPurchasedProductIdentifiers;
  final String originalAppUserId, requestDate;
  final String? managementURL;
  final String _signature;
}

class IntroductoryPrice {
  IntroductoryPrice.fromJson(Map<String, dynamic> json)
      : price = (json['price'] as num).toDouble(),
        priceString = json['priceString'] as String,
        period = json['period'] as String,
        cycles = json['cycles'] as int,
        periodUnit = _named(PeriodUnit.values, json['periodUnit'], PeriodUnit.unknown),
        periodNumberOfUnits = json['periodNumberOfUnits'] as int;
  final double price;
  final String priceString, period;
  final int cycles, periodNumberOfUnits;
  final PeriodUnit periodUnit;
}

enum PeriodUnit { day, week, month, year, unknown }

class StoreProduct {
  StoreProduct.fromJson(Map<String, dynamic> json)
      : identifier = json['identifier'] as String,
        description = json['description'] as String? ?? '',
        title = json['title'] as String? ?? '',
        price = (json['price'] as num).toDouble(),
        priceString = json['priceString'] as String,
        currencyCode = json['currencyCode'] as String? ?? '',
        introductoryPrice = json['introPrice'] == null
            ? null
            : IntroductoryPrice.fromJson(_map(json['introPrice'])),
        productCategory = json['productCategory'] == 'NON_SUBSCRIPTION'
            ? ProductCategory.nonSubscription
            : ProductCategory.subscription,
        subscriptionPeriod = json['subscriptionPeriod'] as String?;
  final String identifier, description, title, priceString, currencyCode;
  final double price;
  final IntroductoryPrice? introductoryPrice;
  final ProductCategory productCategory;

  /// ISO 8601 duration such as `P1M`.
  final String? subscriptionPeriod;
}

class PresentedOfferingContext {
  const PresentedOfferingContext(this.offeringIdentifier);
  final String offeringIdentifier;
}

class Package {
  Package.fromJson(Map<String, dynamic> json)
      : identifier = json['identifier'] as String,
        packageType =
            _named(PackageType.values, json['packageType'], PackageType.unknown),
        storeProduct = StoreProduct.fromJson(_map(json['product'])),
        presentedOfferingContext =
            PresentedOfferingContext(json['offeringIdentifier'] as String);
  final String identifier;
  final PackageType packageType;
  final StoreProduct storeProduct;
  final PresentedOfferingContext presentedOfferingContext;
  String get offeringIdentifier => presentedOfferingContext.offeringIdentifier;
}

class Offering {
  Offering.fromJson(Map<String, dynamic> json)
      : identifier = json['identifier'] as String,
        serverDescription = json['serverDescription'] as String? ?? '',
        metadata = Map.unmodifiable(_map(json['metadata'] ?? const {})),
        availablePackages = List.unmodifiable((json['availablePackages'] as List)
            .map((e) => Package.fromJson(_map(e))));
  final String identifier, serverDescription;
  final Map<String, Object?> metadata;
  final List<Package> availablePackages;
  Package? _first(PackageType type) {
    for (final package in availablePackages) {
      if (package.packageType == type) return package;
    }
    return null;
  }

  Package? get lifetime => _first(PackageType.lifetime);
  Package? get annual => _first(PackageType.annual);
  Package? get sixMonth => _first(PackageType.sixMonth);
  Package? get threeMonth => _first(PackageType.threeMonth);
  Package? get twoMonth => _first(PackageType.twoMonth);
  Package? get monthly => _first(PackageType.monthly);
  Package? get weekly => _first(PackageType.weekly);
  Package? getPackage(String identifier) {
    for (final package in availablePackages) {
      if (package.identifier == identifier) return package;
    }
    return null;
  }
}

class Offerings {
  Offerings.fromJson(Map<String, dynamic> json)
      : all = Map.unmodifiable(_map(json['all'])
            .map((k, v) => MapEntry(k, Offering.fromJson(_map(v))))),
        current = json['current'] == null
            ? null
            : Offering.fromJson(_map(json['current']));
  final Map<String, Offering> all;
  final Offering? current;
  Offering? getOffering(String identifier) => all[identifier];
}

class StoreTransaction {
  StoreTransaction.fromJson(Map<String, dynamic> json)
      : transactionIdentifier = json['transactionIdentifier'] as String?,
        productIdentifier = json['productIdentifier'] as String,
        purchaseDate = json['purchaseDate'] as String;
  final String? transactionIdentifier;
  final String productIdentifier, purchaseDate;
}

class PurchaseResult {
  PurchaseResult.fromJson(Map<String, dynamic> json)
      : customerInfo = CustomerInfo.fromJson(_map(json['customerInfo'])),
        productIdentifier = json['productIdentifier'] as String,
        storeTransaction = json['transaction'] == null
            ? null
            : StoreTransaction.fromJson(_map(json['transaction']));
  final CustomerInfo customerInfo;
  final String productIdentifier;
  final StoreTransaction? storeTransaction;
}

class LogInResult {
  const LogInResult({required this.customerInfo, required this.created});
  final CustomerInfo customerInfo;
  final bool created;
}

class PurchasesConfiguration {
  PurchasesConfiguration(this.apiKey);
  final String apiKey;
  String? appUserID;

  /// Aplyna only: another billing gateway, for self-hosted or test environments.
  String? gatewayUrl;

  /// Aplyna only: catalog project for legacy app-wide keys.
  String? projectId;

  /// Aplyna only, Android: whether the Google account is a Play license tester.
  /// Defaults to true in debuggable builds and false in release builds.
  bool? sandbox;
}

typedef CustomerInfoUpdateListener = void Function(CustomerInfo customerInfo);

/// Entry point with the same names as RevenueCat's `Purchases`.
class Purchases {
  Purchases._();
  static final Set<CustomerInfoUpdateListener> _listeners = {};
  static String? _lastSignature;
  static _ResumeObserver? _observer;

  static Future<dynamic> _call(String method,
      [Map<String, dynamic> args = const {}]) {
    if (kIsWeb ||
        ![TargetPlatform.iOS, TargetPlatform.android]
            .contains(defaultTargetPlatform)) {
      throw PlatformException(
          code: '${PurchasesErrorCode.unsupportedError.index}',
          message: 'Purchases requires native iOS or Android.');
    }
    return Aplyna._invoke('purchases.$method', args);
  }

  static CustomerInfo _info(dynamic json) {
    final info = CustomerInfo.fromJson(_map(json));
    if (info._signature != _lastSignature) {
      _lastSignature = info._signature;
      for (final listener in List.of(_listeners)) {
        listener(info);
      }
    }
    return info;
  }

  static Future<void> configure(PurchasesConfiguration configuration) async {
    await _call('configure', {
      'apiKey': configuration.apiKey,
      if (configuration.appUserID != null) 'appUserID': configuration.appUserID,
      if (configuration.gatewayUrl != null) 'gatewayUrl': configuration.gatewayUrl,
      if (configuration.projectId != null) 'projectId': configuration.projectId,
      if (configuration.sandbox != null) 'sandbox': configuration.sandbox,
    });
    _lastSignature = null;
    // Renewals, cancellations and purchases approved outside the app reach
    // listeners when the app returns to the foreground.
    final binding = WidgetsBinding.instance;
    if (_observer != null) binding.removeObserver(_observer!);
    _observer = _ResumeObserver();
    binding.addObserver(_observer!);
  }

  static Future<bool> get isConfigured async =>
      await _call('isConfigured') as bool;
  static Future<bool> canMakePayments() async =>
      await _call('canMakePayments') as bool;
  static Future<void> setLogLevel(LogLevel level) async {}

  static Future<Offerings> getOfferings() async =>
      Offerings.fromJson(_map(await _call('getOfferings')));

  static Future<PurchaseResult> purchasePackage(Package packageToPurchase) =>
      purchaseStoreProduct(packageToPurchase.storeProduct);

  /// Throws a `PlatformException`; a closed checkout has
  /// `PurchasesErrorCode.purchaseCancelledError` and `details['userCancelled'] == true`.
  static Future<PurchaseResult> purchaseStoreProduct(StoreProduct storeProduct,
      {String? oldProductIdentifier, String? googleReplacementMode}) async {
    final json = _map(await _call('purchaseProduct', {
      'productIdentifier': storeProduct.identifier,
      if (oldProductIdentifier != null)
        'oldProductIdentifier': oldProductIdentifier,
      if (googleReplacementMode != null)
        'googleReplacementMode': googleReplacementMode,
    }));
    _info(json['customerInfo']);
    return PurchaseResult.fromJson(json);
  }

  static Future<CustomerInfo> getCustomerInfo() async =>
      _info(await _call('getCustomerInfo'));
  static Future<CustomerInfo> restorePurchases() async =>
      _info(await _call('restorePurchases'));
  static Future<void> syncPurchases() async {
    _info(await _call('syncPurchases'));
  }

  static Future<void> invalidateCustomerInfoCache() async {
    await _call('invalidateCustomerInfoCache');
  }

  static Future<LogInResult> logIn(String appUserID) async {
    final json = _map(await _call('logIn', {'appUserID': appUserID}));
    return LogInResult(
        customerInfo: _info(json['customerInfo']),
        created: json['created'] as bool);
  }

  static Future<CustomerInfo> logOut() async => _info(await _call('logOut'));
  static Future<String> get appUserID async =>
      _map(await _call('getAppUserID'))['appUserID'] as String;
  static Future<bool> get isAnonymous async =>
      _map(await _call('getAppUserID'))['isAnonymous'] as bool;

  /// Null or empty values delete the attribute.
  static Future<void> setAttributes(Map<String, String?> attributes) async {
    await _call('setAttributes', {'attributes': attributes});
  }

  static Future<void> setEmail(String? email) =>
      setAttributes({r'$email': email});
  static Future<void> setDisplayName(String? displayName) =>
      setAttributes({r'$displayName': displayName});
  static Future<void> setPhoneNumber(String? phoneNumber) =>
      setAttributes({r'$phoneNumber': phoneNumber});
  static Future<void> setPushToken(String? token) => setAttributes({
        defaultTargetPlatform == TargetPlatform.android
            ? r'$fcmTokens'
            : r'$apnsTokens': token
      });

  static void addCustomerInfoUpdateListener(
          CustomerInfoUpdateListener listener) =>
      _listeners.add(listener);
  static void removeCustomerInfoUpdateListener(
          CustomerInfoUpdateListener listener) =>
      _listeners.remove(listener);
}

class _ResumeObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The native layer answers from a fresh cache or fetches when stale.
      Purchases.getCustomerInfo().then((_) {}, onError: (_) {});
    }
  }
}
