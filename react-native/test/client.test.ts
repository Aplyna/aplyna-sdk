import { test } from "node:test";
import assert from "node:assert/strict";
import { createAplyna } from "../src/client";

test("React Native preserves the shared native contract and does not automatically grant consent or expose assignments", async () => {
  const calls: { method: string; args: unknown }[] = [];
  const assignment = {
    flowId: "flow_1",
    experimentId: "exp_1",
    variant: "B" as const,
  };
  const client = createAplyna({
    async invoke(method, json) {
      calls.push({ method, args: JSON.parse(json) });
      return JSON.stringify(
        method === "configure"
          ? { installationId: "stable-id" }
          : method === "assignment"
            ? assignment
            : method === "pendingEventCount"
              ? 2
              : null,
      );
    },
  });
  assert.equal(
    await client.configure({ apiKey: "public-sdk-key" }),
    "stable-id",
  );
  assert.deepEqual(
    calls.map((call) => call.method),
    ["configure"],
  );
  assert.deepEqual(await client.assignment("flow_1"), assignment);
  assert.equal(
    calls.some((call) => call.method === "expose"),
    false,
  );
  await client.setConsent(true);
  await client.setAppLanguage("fr");
  assert.deepEqual(calls.at(-1), {
    method: "setAppLanguage",
    args: { language: "fr" },
  });
  await client.refreshTrackingAuthorizationStatus();
  assert.deepEqual(calls.at(-1), {
    method: "refreshTrackingAuthorizationStatus",
    args: {},
  });
  await client.track("onboarding_step_viewed", {
    flowId: "flow_1",
    stepId: "welcome",
    assignment,
    properties: { screen: "welcome" },
  });
  assert.deepEqual(calls.at(-1)?.args, {
    name: "onboarding_step_viewed",
    flowId: "flow_1",
    stepId: "welcome",
    assignment,
    properties: { screen: "welcome" },
  });
  await client.expose(assignment);
  assert.equal(await client.pendingEventCount(), 2);
  await client.flush();
  await client.setConsent(false);
  assert.equal(calls.at(-1)?.method, "setConsent");
});
test("React Native propagates native delivery errors instead of claiming successful ingestion", async () => {
  const failure = new Error("revoked SDK key");
  const client = createAplyna({
    async invoke() {
      throw failure;
    },
  });
  await assert.rejects(client.flush(), (error) => error === failure);
});
test("billing is explicitly sandbox guarded and independent from analytics consent", async () => {
  const calls: { method: string; args: unknown }[] = [];
  const client = createAplyna({
    async invoke(method, raw) {
      calls.push({ method, args: JSON.parse(raw) });
      return "null";
    },
  });
  await client.billing.configure({
    apiKey: "aplyna_ios_example",
    environment: "sandbox",
  });
  assert.deepEqual(calls, [
    {
      method: "billing.configure",
      args: {
        gatewayUrl: "https://aplyna.com/api/billing",
        sandboxOnly: true,
        apiKey: "aplyna_ios_example",
        environment: "sandbox",
      },
    },
  ]);
  await client.billing.purchase("weekly");
  await client.billing.sync();
  await client.billing.restore();
  await client.billing.storeStatuses();
  await client.billing.manageSubscriptions();
  assert.equal(
    calls.some((c) => c.method === "setConsent" || c.method === "configure"),
    false,
  );
  assert.deepEqual(calls[1], {
    method: "billing.purchase",
    args: { productId: "weekly" },
  });
});

test('Android billing forwards explicit offers and replacements without granting access from the checkout intent', async () => {
  const calls: { method: string; args: unknown }[] = [];
  const verified = { customerId: 'native-customer', environment: 'sandbox', checkedAt: '2026-11-10T12:00:00Z', entitlements: [], subscriptions: [] };
  const sdk = createAplyna({ async invoke(method, json) { calls.push({ method, args: JSON.parse(json) }); return JSON.stringify(method === 'billing.configure' ? { environment: 'sandbox', provider: 'google' } : method === 'billing.manageSubscriptions' ? null : verified); } });
  await sdk.billing.configure({ apiKey: 'aplyna_android_public_test', environment: 'sandbox', googlePlayLicenseTester: true });
  assert.deepEqual(calls[0], { method: 'billing.configure', args: { gatewayUrl: 'https://aplyna.com/api/billing', sandboxOnly: true, apiKey: 'aplyna_android_public_test', environment: 'sandbox', googlePlayLicenseTester: true } });
  const info = await sdk.billing.purchase('subscription:monthly', { basePlanId: 'monthly', offerToken: 'eligible_offer', replacedProductId: 'subscription:weekly', replacementMode: 'with_time_proration' });
  assert.deepEqual(info.entitlements, []);
  assert.deepEqual(calls.at(-1), { method: 'billing.purchase', args: { basePlanId: 'monthly', offerToken: 'eligible_offer', replacedProductId: 'subscription:weekly', replacementMode: 'with_time_proration', productId: 'subscription:monthly' } });
  await sdk.billing.manageSubscriptions('subscription:monthly');
  assert.deepEqual(calls.at(-1), { method: 'billing.manageSubscriptions', args: { productId: 'subscription:monthly' } });
  assert.equal(calls.some(c => c.method === 'configure' || c.method === 'setConsent'), false);
});
