export type Assignment = {
  flowId: string;
  experimentId: string | null;
  variant: "A" | "B";
};
export type TrackOptions = {
  flowId?: string;
  stepId?: string;
  assignment?: Assignment;
  properties?: Record<string, string>;
};
export type Configuration = {
  schema_version: number;
  flow_id: string;
  version: number;
  mode: string;
  steps: Record<string, unknown>[];
};
export interface NativeBridge {
  invoke(method: string, argumentsJSON: string): Promise<string>;
}
export type BillingCustomerInfo = {
  customerId: string;
  environment: "sandbox" | "production";
  checkedAt: string;
  entitlements: {
    identifier: string;
    active: boolean;
    productId: string;
    expiresAt: string | null;
  }[];
  subscriptions?: {
    provider: string;
    productId: string;
    originalTransactionId: string;
    active: boolean;
    status: string;
    expiresAt: string | null;
    autoRenew: boolean | null;
    billingRetry?: boolean | null;
    gracePeriodExpiresAt?: string | null;
  }[];
};
export type BillingProduct = {
  id: string;
  name: string;
  price: string;
  subscriptionGroupId: string | null;
  storeProductId?: string;
  basePlanId?: string;
  offers?: BillingOffer[];
};
export type BillingOffer = {
  basePlanId: string;
  offerId: string | null;
  offerToken: string;
  tags: string[];
  pricingPhases: { price: string; amountMicros: string; currency: string; billingPeriod: string; billingCycleCount: number; recurrenceMode: number }[];
};
export type BillingPurchaseOptions = {
  basePlanId?: string;
  offerToken?: string;
  replacedProductId?: string;
  replacementMode?: "with_time_proration" | "charge_prorated_price" | "without_proration" | "charge_full_price" | "deferred";
};
export type BillingStoreStatus = {
  ownedByCurrentCustomer: boolean;
  productId: string;
  transactionId: string;
  state: string;
  willAutoRenew: boolean | null;
  billingRetry: boolean | null;
  source?: "native_storekit" | "server_verified_google";
  environment: string;
  expiresAt: string | null;
  gracePeriodExpiresAt: string | null;
};

/** A single native client per host app. configure resets consent to false. */
export function createAplyna(bridge: NativeBridge) {
  async function invoke<T>(
    method: string,
    args: Record<string, unknown> = {},
  ): Promise<T> {
    return JSON.parse(await bridge.invoke(method, JSON.stringify(args))) as T;
  }
  return {
    /** Native billing, independent of analytics configuration and consent. */
    billing: {
      configure: (options: {
        apiKey: string;
        environment: "sandbox" | "production";
        sandboxOnly?: boolean;
        googlePlayLicenseTester?: boolean;
        gatewayUrl?: string;
      }) =>
        invoke<{ environment: string }>("billing.configure", {
          gatewayUrl: "https://aplyna.com/api/billing",
          sandboxOnly: true,
          ...options,
        }),
      products: () => invoke<BillingProduct[]>("billing.products"),
      customerInfo: () => invoke<BillingCustomerInfo>("billing.customerInfo"),
      sync: () => invoke<BillingCustomerInfo>("billing.sync"),
      restore: () => invoke<BillingCustomerInfo>("billing.restore"),
      purchase: (productId: string, options: BillingPurchaseOptions = {}) =>
        invoke<BillingCustomerInfo>("billing.purchase", { ...options, productId }),
      manageSubscriptions: (productId?: string) => invoke<void>("billing.manageSubscriptions", productId ? { productId } : {}),
      storeStatuses: () =>
        invoke<BillingStoreStatus[]>("billing.storeStatuses"),
      requestRefund: (productId: string, transactionId: string) =>
        invoke<{ status: string }>("billing.requestRefund", {
          productId,
          transactionId,
        }),
      diagnostics: () =>
        invoke<{ updateError: string | null }>("billing.diagnostics"),
    },
    async configure(options: {
      apiKey: string;
      baseUrl?: string;
      installationId?: string;
    }): Promise<string> {
      const result = await invoke<{ installationId: string }>("configure", {
        baseUrl: "https://aplyna.com",
        ...options,
      });
      return result.installationId;
    },
    async setConsent(granted: boolean): Promise<void> {
      await invoke("setConsent", { granted });
    },
    /** Set the actual runtime language for apps using JavaScript localization. */
    async setAppLanguage(language: string | null): Promise<void> {
      await invoke("setAppLanguage", { language });
    },
    /** iOS only: collect Apple Ads attribution after analytics consent. */
    async collectAppleAdsAttribution(): Promise<void> {
      await invoke("collectAppleAdsAttribution");
    },
    /** iOS only: read ATT after your native permission callback, then flush. */
    async refreshTrackingAuthorizationStatus(): Promise<void> {
      await invoke("refreshTrackingAuthorizationStatus");
    },
    async track(name: string, options: TrackOptions = {}): Promise<void> {
      await invoke("track", { ...options, name });
    },
    async expose(assignment: Assignment): Promise<void> {
      await invoke("expose", { assignment });
    },
    async flush(): Promise<void> {
      await invoke("flush");
    },
    pendingEventCount: () => invoke<number>("pendingEventCount"),
    assignment: (flowId: string) =>
      invoke<Assignment>("assignment", { flowId }),
    configuration: (flowId: string) =>
      invoke<Configuration>("configuration", { flowId }),
  };
}
