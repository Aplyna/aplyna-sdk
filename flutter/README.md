# Aplyna for Flutter

Plugin `aplyna` for iOS 16+ and Android 23+. Dart 3.5+, Flutter 3.24+.

## Install

```yaml
dependencies:
  aplyna:
    git:
      url: https://github.com/aplyna/aplyna-sdk.git
      path: flutter
      ref: 1.0.0
```

## Use

```dart
import 'package:aplyna/aplyna.dart';

await Purchases.configure(PurchasesConfiguration('aplyna_ios_… or aplyna_android_…'));

final offerings = await Purchases.getOfferings();
try {
  final result = await Purchases.purchasePackage(offerings.current!.monthly!);
  final unlocked = result.customerInfo.entitlements.active.containsKey('premium');
} on PlatformException catch (e) {
  if (PurchasesErrorHelper.getErrorCode(e) != PurchasesErrorCode.purchaseCancelledError) rethrow;
}

await Purchases.restorePurchases();
await Purchases.logIn('user_123');
await Purchases.setAttributes({'plan': 'gold'});
Purchases.addCustomerInfoUpdateListener((info) {});
```

Names, models and `PurchasesErrorCode` values match `purchases_flutter`. Listener updates arrive after each call and when the app returns to the foreground.

The `Aplyna` class provides events, experiment assignments and remote configuration; see the [documentation](https://aplyna.com/docs).
