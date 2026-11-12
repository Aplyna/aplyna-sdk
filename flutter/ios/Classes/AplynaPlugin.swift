import Flutter
import Foundation

public final class AplynaPlugin: NSObject, FlutterPlugin {
    private let bridge = AplynaBridge()
    private let billing = AplynaBillingBridge()
    private let purchases = PurchasesBridge()
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.aplyna/sdk", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(AplynaPlugin(), channel: channel)
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "invoke" else { result(FlutterMethodNotImplemented); return }
        guard let args = call.arguments as? [String: Any], let method = args["method"] as? String, let json = args["argumentsJSON"] as? String else {
            result(FlutterError(code: "APLYNA_ARGUMENTS", message: "Use a method and JSON arguments.", details: nil)); return
        }
        Task { @MainActor in
            do {
                if method.hasPrefix("purchases.") {
                    // RevenueCat-compatible API: numeric error code, readable code and userCancelled in details.
                    do { result(try await purchases.invoke(method: method, argumentsJSON: json)) }
                    catch { let payload = PurchasesBridge.errorPayload(error); result(FlutterError(code: payload.code, message: payload.message, details: payload.details)) }
                    return
                }
                if method.hasPrefix("billing.") { result(try await billing.invoke(method: method, argumentsJSON: json)) }
                else { result(try await bridge.invoke(method: method, argumentsJSON: json)) }
            }
            catch let error as AplynaBillingError { result(FlutterError(code: error.code, message: error.localizedDescription, details: nil)) }
            catch { result(FlutterError(code: "APLYNA_SDK", message: error.localizedDescription, details: nil)) }
        }
    }
}
