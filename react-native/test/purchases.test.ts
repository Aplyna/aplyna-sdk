import { test } from "node:test";
import assert from "node:assert/strict";
import { createPurchases, PURCHASES_ERROR_CODE, PACKAGE_TYPE, toPurchasesError, type CustomerInfo } from "../src/purchases";

const entitlement = (active = true) => ({
  identifier: "premium", isActive: active, willRenew: active, periodType: "TRIAL", latestPurchaseDate: null, originalPurchaseDate: null,
  expirationDate: "2099-01-01T00:00:00.000Z", store: "APP_STORE", productIdentifier: "monthly", isSandbox: true,
  unsubscribeDetectedAt: null, billingIssueDetectedAt: null, ownershipType: "PURCHASED",
});
const customerInfo = (active = true) => ({
  entitlements: { all: { premium: entitlement(active) }, active: active ? { premium: entitlement() } : {} },
  activeSubscriptions: active ? ["monthly"] : [], allPurchasedProductIdentifiers: ["monthly"], latestExpirationDate: "2099-01-01T00:00:00.000Z",
  allExpirationDates: { monthly: "2099-01-01T00:00:00.000Z" }, originalAppUserId: "user_1", requestDate: "2026-11-12T11:59:00.000Z",
  managementURL: "https://apps.apple.com/account/subscriptions",
});
const pack = (identifier: string, type: string, product: string) => ({
  identifier, packageType: type, offeringIdentifier: "default", presentedOfferingContext: { offeringIdentifier: "default" },
  product: { identifier: product, title: "Premium", description: "", price: 9.99, priceString: "9,99 €", currencyCode: "EUR", productCategory: "SUBSCRIPTION", subscriptionPeriod: "P1M", introPrice: null },
});
function harness(respond: (method: string, args: any) => unknown) {
  const calls: { method: string; args: any }[] = [];
  let foreground: (() => void) | undefined;
  const purchases = createPurchases(
    { async invoke(method, json) { const args = JSON.parse(json); calls.push({ method, args }); return JSON.stringify(respond(method, args) ?? null); } },
    (refresh) => { foreground = refresh; },
  );
  return { purchases, calls, resume: () => foreground?.() };
}

test("configure returns immediately and later calls wait for it, with RevenueCat call names", async () => {
  const order: string[] = [];
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const purchases = createPurchases({
    async invoke(method) {
      if (method === "purchases.configure") { await gate; order.push("configured"); return "null"; }
      order.push(method);
      return JSON.stringify(method === "purchases.getAppUserID" ? { appUserID: "user_1", isAnonymous: false } : customerInfo());
    },
  });
  assert.equal(purchases.configure({ apiKey: "aplyna_ios_key", appUserID: "user_1" }), undefined);
  const pending = purchases.getAppUserID();
  release();
  assert.equal(await pending, "user_1");
  assert.deepEqual(order, ["configured", "purchases.getAppUserID"]);
  assert.equal(await purchases.isAnonymous(), false);
});

test("offerings, purchase and customer info keep the react-native-purchases shapes", async () => {
  const monthly = pack("$rc_monthly", "MONTHLY", "monthly");
  const offering = { identifier: "default", serverDescription: "Standard", metadata: {}, availablePackages: [monthly], monthly };
  const { purchases, calls } = harness((method) =>
    method === "purchases.getOfferings" ? { all: { default: offering }, current: offering }
    : method === "purchases.purchaseProduct" ? { customerInfo: customerInfo(), productIdentifier: "monthly", transaction: { transactionIdentifier: "2000001", productIdentifier: "monthly", purchaseDate: "2026-11-12T12:00:00.000Z" } }
    : method === "purchases.logIn" ? { customerInfo: customerInfo(), created: true }
    : customerInfo());
  purchases.configure({ apiKey: "aplyna_ios_key" });
  const offerings = await purchases.getOfferings();
  assert.equal(offerings.current?.monthly?.packageType, PACKAGE_TYPE.MONTHLY);
  assert.equal(offerings.current?.availablePackages[0].product.priceString, "9,99 €");
  const result = await purchases.purchasePackage(offerings.current!.monthly!);
  assert.deepEqual(calls.at(-1), { method: "purchases.purchaseProduct", args: { productIdentifier: "monthly" } });
  assert.equal(result.productIdentifier, "monthly");
  assert.equal(result.customerInfo.entitlements.active.premium.isActive, true);
  assert.equal(result.transaction?.transactionIdentifier, "2000001");
  assert.equal(typeof (await purchases.getCustomerInfo()).entitlements.active.premium, "object");
  const login = await purchases.logIn("user_2");
  assert.equal(login.created, true);
  assert.deepEqual(calls.at(-1), { method: "purchases.logIn", args: { appUserID: "user_2" } });
});

test("listeners fire once per change, on foreground refresh too", async () => {
  let active = true;
  const { purchases, resume } = harness(() => customerInfo(active));
  const seen: CustomerInfo[] = [];
  const listener = (value: CustomerInfo) => { seen.push(value); };
  purchases.addCustomerInfoUpdateListener(listener);
  purchases.configure({ apiKey: "aplyna_ios_key" });
  await purchases.getCustomerInfo();
  await purchases.restorePurchases();
  assert.equal(seen.length, 1);
  active = false;
  resume();
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(seen.length, 2);
  assert.deepEqual(seen[1].entitlements.active, {});
  assert.equal(purchases.removeCustomerInfoUpdateListener(listener), true);
  active = true;
  await purchases.getCustomerInfo();
  assert.equal(seen.length, 2);
});

test("native rejections become PurchasesError with code, userCancelled and readable code", async () => {
  const reject = (code: string, message = "native") => createPurchases({ async invoke() { throw Object.assign(new Error(message), { code }); } });
  await assert.rejects(reject("1").purchaseStoreProduct(pack("p", "CUSTOM", "monthly").product as any), (error: any) => {
    assert.equal(error.code, PURCHASES_ERROR_CODE.PURCHASE_CANCELLED_ERROR);
    assert.equal(error.userCancelled, true);
    assert.equal(error.readableErrorCode, "PURCHASE_CANCELLED");
    assert.equal(error.userInfo.readableErrorCode, "PURCHASE_CANCELLED");
    return true;
  });
  for (const [code, expected, name] of [["20", PURCHASES_ERROR_CODE.PAYMENT_PENDING_ERROR, "PAYMENT_PENDING_ERROR"], ["35", PURCHASES_ERROR_CODE.OFFLINE_CONNECTION_ERROR, "OFFLINE_CONNECTION_ERROR"],
    ["15", PURCHASES_ERROR_CODE.OPERATION_ALREADY_IN_PROGRESS_ERROR, "OPERATION_ALREADY_IN_PROGRESS"], ["7", PURCHASES_ERROR_CODE.RECEIPT_ALREADY_IN_USE_ERROR, "RECEIPT_ALREADY_IN_USE"],
    ["22", PURCHASES_ERROR_CODE.LOG_OUT_ANONYMOUS_USER_ERROR, "LOGOUT_CALLED_WITH_ANONYMOUS_USER"]] as const)
    await assert.rejects(reject(code).getCustomerInfo(), (error: any) => error.code === expected && error.userCancelled === false && error.readableErrorCode === name);
  // Unknown or non-numeric native codes never look like a cancellation.
  for (const code of ["APLYNA_SDK", "999", ""]) assert.equal(toPurchasesError({ code, message: "x" }).code, PURCHASES_ERROR_CODE.UNKNOWN_ERROR);
  assert.equal(toPurchasesError(undefined).userCancelled, false);
  // A failed configure surfaces on the next call instead of being lost.
  const failing = createPurchases({ async invoke(method) { if (method === "purchases.configure") throw Object.assign(new Error("bad key"), { code: "11" }); return "null"; } });
  failing.configure({ apiKey: "wrong" });
  assert.equal(await failing.isConfigured(), null);
});

test("attributes use the reserved keys and allow deletion", async () => {
  const { purchases, calls } = harness(() => null);
  await purchases.setAttributes({ plan: "gold", old: null });
  assert.deepEqual(calls.at(-1), { method: "purchases.setAttributes", args: { attributes: { plan: "gold", old: null } } });
  await purchases.setEmail("a@example.com");
  assert.deepEqual(calls.at(-1)?.args, { attributes: { $email: "a@example.com" } });
  await purchases.setPushToken("t", "android");
  assert.deepEqual(calls.at(-1)?.args, { attributes: { $fcmTokens: "t" } });
});
