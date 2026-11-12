import NativeAplyna from "./specs/NativeAplyna";
import { AppState } from "react-native";
import { createAplyna } from "./client";
import { createPurchases } from "./purchases";
export type {
  Assignment,
  Configuration,
  TrackOptions,
  BillingCustomerInfo,
  BillingProduct,
  BillingOffer,
  BillingPurchaseOptions,
  BillingStoreStatus,
} from "./client";
export const Aplyna = createAplyna(NativeAplyna);
/** Same API as react-native-purchases: `import { Purchases } from "@aplyna/react-native"`. */
export const Purchases = createPurchases(NativeAplyna, (refresh) => {
  AppState.addEventListener("change", (state) => {
    if (state === "active") refresh();
  });
});
export { PURCHASES_ERROR_CODE, PACKAGE_TYPE, LOG_LEVEL } from "./purchases";
export type {
  CustomerInfo,
  PurchasesEntitlementInfo,
  PurchasesEntitlementInfos,
  PurchasesOfferings,
  PurchasesOffering,
  PurchasesPackage,
  PurchasesStoreProduct,
  PurchasesIntroPrice,
  PurchasesStoreTransaction,
  PurchasesConfiguration,
  PurchasesError,
  MakePurchaseResult,
  LogInResult,
  CustomerInfoUpdateListener,
} from "./purchases";
export default Aplyna;
