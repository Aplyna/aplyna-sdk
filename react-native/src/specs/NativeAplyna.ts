import type { TurboModule } from "react-native";
import { TurboModuleRegistry } from "react-native";

export interface Spec extends TurboModule {
  invoke(method: string, argumentsJSON: string): Promise<string>;
}
export default TurboModuleRegistry.getEnforcing<Spec>("Aplyna");
