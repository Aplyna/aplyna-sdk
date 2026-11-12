# Aplyna SDK

In-app purchases, subscriptions, offerings and customer attributes for iOS, Android, Flutter and React Native, backed by the [Aplyna](https://aplyna.com) billing service.

The `Purchases` API uses the same names, shapes and error codes as RevenueCat's SDKs, so an app that already uses RevenueCat can switch by changing its import and its API key. The implementation is Aplyna's own and talks only to Aplyna.

| Platform     | Folder                           | Install                                                        |
| ------------ | -------------------------------- | -------------------------------------------------------------- |
| iOS (Swift)  | [`ios`](ios)                     | Swift Package Manager: this repository, from `1.0.0`           |
| Android      | [`android`](android)             | Gradle module from this repository                             |
| Flutter      | [`flutter`](flutter)             | Git dependency on this repository, path `flutter`              |
| React Native | [`react-native`](react-native)   | Local package from this repository                             |

## Quick start

Use the store key of your app from **Apps & API keys** in the Aplyna dashboard (`aplyna_ios_…` or `aplyna_android_…`).

```swift
import Aplyna

Purchases.configure(withAPIKey: "aplyna_ios_…")

let offerings = try await Purchases.shared.getOfferings()
if let package = offerings.current?.monthly {
    let result = try await Purchases.shared.purchase(package: package)
    if !result.userCancelled, result.customerInfo.entitlements["premium"]?.isActive == true {
        // unlock
    }
}
```

Offerings come from **Product catalog → Offerings** in the dashboard. Access is granted only from purchases the Aplyna service has verified with the store.

## What is included

- Offerings and packages with live store prices
- Purchase, restore, customer info with caching, and update listeners
- Trials, renewals, plan changes, billing issues with grace, cancellation
- `logIn` / `logOut` with anonymous IDs, and customer attributes
- RevenueCat-compatible error codes, including cancelled, pending, offline and already-in-progress
- Events, assignments and remote configuration through `AplynaClient`

## Differences from RevenueCat

- `logIn` labels this install's customer with your user ID. It does not yet share purchases between devices.
- Promotional offers, offer codes, eligibility checks, paywall UI, customer center, virtual currencies, web purchases and Amazon are not included.
- `entitlements.all` lists granted entitlements only.
- On Android, debuggable builds use the sandbox environment and release builds use production; override with `sandbox(…)` on the configuration builder.

## Requirements

iOS 16+ (StoreKit 2), Android API 23+ (Play Billing 9), Flutter 3.24+, React Native 0.76+ (new architecture).

## License

[MIT](LICENSE)
