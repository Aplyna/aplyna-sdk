# Aplyna for iOS

Swift package `Aplyna`, iOS 16+, StoreKit 2.

## Install

In Xcode: **File → Add Package Dependencies…**, enter `https://github.com/aplyna/aplyna-sdk`, and choose version `1.0.0` or later. Or in `Package.swift`:

```swift
.package(url: "https://github.com/aplyna/aplyna-sdk", from: "1.0.0")
```

## Use

```swift
import Aplyna

Purchases.configure(withAPIKey: "aplyna_ios_…")            // optionally appUserID:

let offerings = try await Purchases.shared.getOfferings()
let result = try await Purchases.shared.purchase(package: offerings.current!.monthly!)
let info = try await Purchases.shared.getCustomerInfo()
let unlocked = info.entitlements["premium"]?.isActive == true

try await Purchases.shared.restorePurchases()
try await Purchases.shared.logIn("user_123")
Purchases.shared.attribution.setAttributes(["plan": "gold"])
for await info in Purchases.shared.customerInfoStream { /* updates */ }
```

Errors cast to `ErrorCode` with RevenueCat's values (`.purchaseCancelledError`, `.networkError`, `.paymentPendingError`, …). A cancelled purchase returns `userCancelled == true` instead of throwing. The sandbox or production environment is detected from the App Store.

`AplynaClient` provides events, experiment assignments and remote configuration; see the [documentation](https://aplyna.com/docs).
