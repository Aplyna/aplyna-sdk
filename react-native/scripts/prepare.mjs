import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
const directory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const preparation = resolve(
  directory,
  "../../scripts/prepare-sdk-packages.mjs",
);
if (existsSync(preparation))
  execFileSync(process.execPath, [preparation], { stdio: "inherit" });
for (const file of [
  "ios/Core/AplynaClient.swift",
  "ios/Core/AplynaBridge.swift",
  "ios/Core/AplynaBillingClient.swift",
  "ios/Core/AplynaBillingBridge.swift",
  "android/src/main/java/com/aplyna/sdk/AplynaClient.kt",
  "android/src/main/java/com/aplyna/sdk/AplynaBridge.kt",
  "android/src/main/java/com/aplyna/sdk/AplynaBillingModels.kt",
  "android/src/main/java/com/aplyna/sdk/AplynaBillingStorage.kt",
  "android/src/main/java/com/aplyna/sdk/AplynaBillingGateway.kt",
  "android/src/main/java/com/aplyna/sdk/AplynaBillingClient.kt",
  "android/src/main/java/com/aplyna/sdk/AplynaBillingBridge.kt",
]) {
  if (!existsSync(resolve(directory, file)))
    throw Error(
      `Missing ${file}. Run npm run sdk:prepare from the Aplyna repository before packaging.`,
    );
}
