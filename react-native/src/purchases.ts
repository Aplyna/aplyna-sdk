// Aplyna's purchase API uses the same names and shapes as RevenueCat's react-native-purchases
// so an app can switch by changing its import and API key. Independent implementation; it
// talks only to the Aplyna billing gateway.
import type { NativeBridge } from "./client";

/** Same names and values as react-native-purchases' PURCHASES_ERROR_CODE. */
export enum PURCHASES_ERROR_CODE {
  UNKNOWN_ERROR = "0",
  PURCHASE_CANCELLED_ERROR = "1",
  STORE_PROBLEM_ERROR = "2",
  PURCHASE_NOT_ALLOWED_ERROR = "3",
  PURCHASE_INVALID_ERROR = "4",
  PRODUCT_NOT_AVAILABLE_FOR_PURCHASE_ERROR = "5",
  PRODUCT_ALREADY_PURCHASED_ERROR = "6",
  RECEIPT_ALREADY_IN_USE_ERROR = "7",
  INVALID_RECEIPT_ERROR = "8",
  MISSING_RECEIPT_FILE_ERROR = "9",
  NETWORK_ERROR = "10",
  INVALID_CREDENTIALS_ERROR = "11",
  UNEXPECTED_BACKEND_RESPONSE_ERROR = "12",
  RECEIPT_IN_USE_BY_OTHER_SUBSCRIBER_ERROR = "13",
  INVALID_APP_USER_ID_ERROR = "14",
  OPERATION_ALREADY_IN_PROGRESS_ERROR = "15",
  UNKNOWN_BACKEND_ERROR = "16",
  INVALID_APPLE_SUBSCRIPTION_KEY_ERROR = "17",
  INELIGIBLE_ERROR = "18",
  INSUFFICIENT_PERMISSIONS_ERROR = "19",
  PAYMENT_PENDING_ERROR = "20",
  INVALID_SUBSCRIBER_ATTRIBUTES_ERROR = "21",
  LOG_OUT_ANONYMOUS_USER_ERROR = "22",
  CONFIGURATION_ERROR = "23",
  UNSUPPORTED_ERROR = "24",
  EMPTY_SUBSCRIBER_ATTRIBUTES_ERROR = "25",
  PRODUCT_DISCOUNT_MISSING_IDENTIFIER_ERROR = "26",
  PRODUCT_DISCOUNT_MISSING_SUBSCRIPTION_GROUP_IDENTIFIER_ERROR = "28",
  CUSTOMER_INFO_ERROR = "29",
  SYSTEM_INFO_ERROR = "30",
  BEGIN_REFUND_REQUEST_ERROR = "31",
  PRODUCT_REQUEST_TIMED_OUT_ERROR = "32",
  API_ENDPOINT_BLOCKED = "33",
  INVALID_PROMOTIONAL_OFFER_ERROR = "34",
  OFFLINE_CONNECTION_ERROR = "35",
}

export enum PACKAGE_TYPE {
  UNKNOWN = "UNKNOWN",
  CUSTOM = "CUSTOM",
  LIFETIME = "LIFETIME",
  ANNUAL = "ANNUAL",
  SIX_MONTH = "SIX_MONTH",
  THREE_MONTH = "THREE_MONTH",
  TWO_MONTH = "TWO_MONTH",
  MONTHLY = "MONTHLY",
  WEEKLY = "WEEKLY",
}

export enum LOG_LEVEL {
  VERBOSE = "VERBOSE",
  DEBUG = "DEBUG",
  INFO = "INFO",
  WARN = "WARN",
  ERROR = "ERROR",
}

export type PurchasesEntitlementInfo = {
  identifier: string;
  isActive: boolean;
  willRenew: boolean;
  periodType: "NORMAL" | "INTRO" | "TRIAL" | "PREPAID";
  latestPurchaseDate: string | null;
  originalPurchaseDate: string | null;
  expirationDate: string | null;
  store: "APP_STORE" | "PLAY_STORE" | "UNKNOWN_STORE" | string;
  productIdentifier: string;
  productPlanIdentifier?: string | null;
  isSandbox: boolean;
  unsubscribeDetectedAt: string | null;
  billingIssueDetectedAt: string | null;
  ownershipType: "PURCHASED" | "FAMILY_SHARED" | "UNKNOWN";
};
export type PurchasesEntitlementInfos = {
  all: Record<string, PurchasesEntitlementInfo>;
  active: Record<string, PurchasesEntitlementInfo>;
};
export type CustomerInfo = {
  entitlements: PurchasesEntitlementInfos;
  activeSubscriptions: string[];
  allPurchasedProductIdentifiers: string[];
  latestExpirationDate: string | null;
  allExpirationDates: Record<string, string | null>;
  originalAppUserId: string;
  requestDate: string;
  managementURL: string | null;
};
export type PurchasesIntroPrice = {
  price: number;
  priceString: string;
  period: string;
  cycles: number;
  periodUnit: "DAY" | "WEEK" | "MONTH" | "YEAR" | "UNKNOWN";
  periodNumberOfUnits: number;
};
export type PurchasesStoreProduct = {
  identifier: string;
  title: string;
  description: string;
  price: number;
  priceString: string;
  currencyCode: string | null;
  productCategory: "SUBSCRIPTION" | "NON_SUBSCRIPTION";
  subscriptionPeriod: string | null;
  introPrice: PurchasesIntroPrice | null;
};
export type PurchasesPackage = {
  identifier: string;
  packageType: PACKAGE_TYPE | `${PACKAGE_TYPE}`;
  product: PurchasesStoreProduct;
  offeringIdentifier: string;
  presentedOfferingContext: { offeringIdentifier: string };
};
export type PurchasesOffering = {
  identifier: string;
  serverDescription: string;
  metadata: Record<string, unknown>;
  availablePackages: PurchasesPackage[];
  lifetime?: PurchasesPackage;
  annual?: PurchasesPackage;
  sixMonth?: PurchasesPackage;
  threeMonth?: PurchasesPackage;
  twoMonth?: PurchasesPackage;
  monthly?: PurchasesPackage;
  weekly?: PurchasesPackage;
};
export type PurchasesOfferings = {
  all: Record<string, PurchasesOffering>;
  current: PurchasesOffering | null;
};
export type PurchasesStoreTransaction = {
  transactionIdentifier?: string;
  productIdentifier: string;
  purchaseDate: string;
};
export type MakePurchaseResult = {
  customerInfo: CustomerInfo;
  productIdentifier: string;
  transaction?: PurchasesStoreTransaction;
};
export type LogInResult = { customerInfo: CustomerInfo; created: boolean };
export type PurchasesConfiguration = {
  apiKey: string;
  appUserID?: string | null;
  /** Aplyna only: another billing gateway, for self-hosted or test environments. */
  gatewayUrl?: string;
  /** Aplyna only: catalog project for legacy app-wide keys. */
  projectId?: string;
  /** Aplyna only, Android: whether the Google account is a Play license tester. */
  sandbox?: boolean;
};
/** Same fields as react-native-purchases' PurchasesError. */
export type PurchasesError = Error & {
  code: PURCHASES_ERROR_CODE | string;
  userCancelled: boolean;
  readableErrorCode: string;
  underlyingErrorMessage: string;
  userInfo: { readableErrorCode: string };
};
export type CustomerInfoUpdateListener = (customerInfo: CustomerInfo) => void;

const readable: Record<string, string> = {
  "0": "UNKNOWN", "1": "PURCHASE_CANCELLED", "2": "STORE_PROBLEM", "3": "PURCHASE_NOT_ALLOWED", "4": "PURCHASE_INVALID",
  "5": "PRODUCT_NOT_AVAILABLE_FOR_PURCHASE", "6": "PRODUCT_ALREADY_PURCHASED", "7": "RECEIPT_ALREADY_IN_USE", "8": "INVALID_RECEIPT",
  "9": "MISSING_RECEIPT_FILE", "10": "NETWORK_ERROR", "11": "INVALID_CREDENTIALS", "12": "UNEXPECTED_BACKEND_RESPONSE_ERROR",
  "14": "INVALID_APP_USER_ID", "15": "OPERATION_ALREADY_IN_PROGRESS", "16": "UNKNOWN_BACKEND_ERROR", "17": "INVALID_APPLE_SUBSCRIPTION_KEY",
  "18": "INELIGIBLE_ERROR", "19": "INSUFFICIENT_PERMISSIONS_ERROR", "20": "PAYMENT_PENDING_ERROR", "21": "INVALID_SUBSCRIBER_ATTRIBUTES",
  "22": "LOGOUT_CALLED_WITH_ANONYMOUS_USER", "23": "CONFIGURATION_ERROR", "24": "UNSUPPORTED_ERROR", "25": "EMPTY_SUBSCRIBER_ATTRIBUTES",
  "29": "CUSTOMER_INFO_ERROR", "32": "PRODUCT_REQUEST_TIMED_OUT_ERROR", "34": "INVALID_PROMOTIONAL_OFFER_ERROR", "35": "OFFLINE_CONNECTION_ERROR",
};

/** Normalizes a native rejection into the react-native-purchases error shape. */
export function toPurchasesError(raw: unknown): PurchasesError {
  const source = (raw ?? {}) as { code?: unknown; message?: unknown };
  const code = typeof source.code === "string" && /^\d+$/.test(source.code) && readable[source.code] ? source.code : PURCHASES_ERROR_CODE.UNKNOWN_ERROR;
  const message = typeof source.message === "string" && source.message ? source.message : "Unknown error.";
  const error = (raw instanceof Error ? raw : new Error(message)) as PurchasesError;
  error.code = code;
  error.userCancelled = code === PURCHASES_ERROR_CODE.PURCHASE_CANCELLED_ERROR;
  error.readableErrorCode = readable[code];
  error.underlyingErrorMessage = message;
  error.userInfo = { readableErrorCode: readable[code] };
  return error;
}

/**
 * `onForeground` lets the host re-check customer info when the app returns to the
 * foreground, so renewals and purchases approved outside the app reach listeners.
 */
export function createPurchases(bridge: NativeBridge, onForeground?: (refresh: () => void) => void) {
  const listeners = new Set<CustomerInfoUpdateListener>();
  let signature: string | null = null;
  let ready: Promise<unknown> = Promise.resolve();
  let watching = false;

  async function invoke<T>(method: string, args: Record<string, unknown> = {}): Promise<T> {
    // Calls made right after configure wait for it, as configure itself returns immediately.
    await ready.catch(() => undefined);
    try { return JSON.parse(await bridge.invoke(`purchases.${method}`, JSON.stringify(args))) as T; }
    catch (error) { throw toPurchasesError(error); }
  }
  function publish(info: CustomerInfo): CustomerInfo {
    const next = JSON.stringify([info.entitlements, info.activeSubscriptions, info.allExpirationDates, info.originalAppUserId]);
    if (next !== signature) {
      signature = next;
      for (const listener of [...listeners]) listener(info);
    }
    return info;
  }
  const info = (method: string, args?: Record<string, unknown>) => invoke<CustomerInfo>(method, args).then(publish);
  const purchase = (identifier: string, options: { oldProductIdentifier?: string; googleReplacementMode?: string } = {}) =>
    invoke<MakePurchaseResult>("purchaseProduct", { productIdentifier: identifier, ...options }).then((result) => {
      publish(result.customerInfo);
      return result;
    });

  const api = {
    /** Returns immediately, like react-native-purchases; later calls wait for it to finish. */
    configure(configuration: PurchasesConfiguration): void {
      const { apiKey, appUserID, gatewayUrl, projectId, sandbox } = configuration;
      signature = null;
      ready = bridge
        .invoke("purchases.configure", JSON.stringify({
          apiKey,
          ...(appUserID ? { appUserID } : {}), ...(gatewayUrl ? { gatewayUrl } : {}),
          ...(projectId ? { projectId } : {}), ...(sandbox === undefined ? {} : { sandbox }),
        }))
        .catch((error) => { throw toPurchasesError(error); });
      ready.catch(() => undefined);
      if (!watching && onForeground) {
        watching = true;
        onForeground(() => { api.getCustomerInfo().catch(() => undefined); });
      }
    },
    isConfigured: () => invoke<boolean>("isConfigured"),
    canMakePayments: () => invoke<boolean>("canMakePayments"),
    setLogLevel: async (_level: LOG_LEVEL | `${LOG_LEVEL}`): Promise<void> => undefined,
    getOfferings: () => invoke<PurchasesOfferings>("getOfferings"),
    /** Rejects with a PurchasesError; a closed checkout has `userCancelled === true`. */
    purchasePackage: (aPackage: PurchasesPackage, options?: { oldProductIdentifier?: string; googleReplacementMode?: string }) =>
      purchase(aPackage.product.identifier, options),
    purchaseStoreProduct: (product: PurchasesStoreProduct, options?: { oldProductIdentifier?: string; googleReplacementMode?: string }) =>
      purchase(product.identifier, options),
    getCustomerInfo: () => info("getCustomerInfo"),
    restorePurchases: () => info("restorePurchases"),
    syncPurchases: async (): Promise<void> => { await info("syncPurchases"); },
    invalidateCustomerInfoCache: () => invoke<void>("invalidateCustomerInfoCache"),
    logIn: (appUserID: string) =>
      invoke<LogInResult>("logIn", { appUserID }).then((result) => { publish(result.customerInfo); return result; }),
    logOut: () => info("logOut"),
    getAppUserID: () => invoke<{ appUserID: string }>("getAppUserID").then((value) => value.appUserID),
    isAnonymous: () => invoke<{ isAnonymous: boolean }>("getAppUserID").then((value) => value.isAnonymous),
    /** Null or empty values delete the attribute. */
    setAttributes: (attributes: Record<string, string | null>) => invoke<void>("setAttributes", { attributes }),
    setEmail: (email: string | null) => api.setAttributes({ $email: email }),
    setDisplayName: (displayName: string | null) => api.setAttributes({ $displayName: displayName }),
    setPhoneNumber: (phoneNumber: string | null) => api.setAttributes({ $phoneNumber: phoneNumber }),
    /** Pass the platform push token; `platform` chooses the reserved key. */
    setPushToken: (token: string | null, platform: "ios" | "android" = "ios") =>
      api.setAttributes({ [platform === "android" ? "$fcmTokens" : "$apnsTokens"]: token }),
    addCustomerInfoUpdateListener(listener: CustomerInfoUpdateListener): void { listeners.add(listener); },
    removeCustomerInfoUpdateListener: (listener: CustomerInfoUpdateListener): boolean => listeners.delete(listener),
    PURCHASES_ERROR_CODE,
    PACKAGE_TYPE,
    LOG_LEVEL,
  };
  return api;
}
