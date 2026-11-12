import Foundation
import React

@objc(AplynaReactNativeAdapter)
public final class AplynaReactNativeAdapter: NSObject {
    private let bridge = AplynaBridge()
    private let billing = AplynaBillingBridge()
    private let purchases = PurchasesBridge()
    @objc(invoke:argumentsJSON:resolve:reject:)
    public func invoke(_ method: String, argumentsJSON: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        Task {
            do {
                if method.hasPrefix("purchases.") {
                    // RevenueCat-compatible API: the numeric error code is the rejection code.
                    do { resolve(try await purchases.invoke(method: method, argumentsJSON: argumentsJSON)) }
                    catch { let payload = PurchasesBridge.errorPayload(error); reject(payload.code, payload.message, error) }
                    return
                }
                if method.hasPrefix("billing.") { resolve(try await billing.invoke(method: method, argumentsJSON: argumentsJSON)) }
                else { resolve(try await bridge.invoke(method: method, argumentsJSON: argumentsJSON)) }
            }
            catch let error as AplynaBillingError { reject(error.code, error.localizedDescription, error) }
            catch { reject("APLYNA_SDK", error.localizedDescription, error) }
        }
    }
}
