# Aplyna for React Native

Package `@aplyna/react-native` for iOS 16+ and Android 24+, React Native 0.76+ with the new architecture (Turbo Native Module).

## Install

Clone this repository, then:

```sh
npm install ../aplyna-sdk/react-native
cd ios && pod install
```

## Use

```ts
import { Purchases, PURCHASES_ERROR_CODE } from "@aplyna/react-native";

Purchases.configure({ apiKey: "aplyna_ios_… or aplyna_android_…" });

const offerings = await Purchases.getOfferings();
try {
  const { customerInfo } = await Purchases.purchasePackage(offerings.current!.monthly!);
  const unlocked = customerInfo.entitlements.active.premium !== undefined;
} catch (e: any) {
  if (!e.userCancelled) throw e;
}

await Purchases.restorePurchases();
await Purchases.logIn("user_123");
await Purchases.setAttributes({ plan: "gold" });
Purchases.addCustomerInfoUpdateListener((info) => {});
```

Names, shapes and `PURCHASES_ERROR_CODE` values match `react-native-purchases`; the import is a named export instead of the default export.

The default `Aplyna` export provides events, experiment assignments and remote configuration; see the [documentation](https://aplyna.com/docs).
