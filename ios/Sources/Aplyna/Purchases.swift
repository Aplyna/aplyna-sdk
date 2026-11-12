import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

public protocol PurchasesDelegate: AnyObject {
    /// Called whenever a newer server-verified customer info is available: after a purchase,
    /// a renewal, a restore, or a purchase approved outside the app.
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo)
}

/// Configuration with the same builder as RevenueCat's.
public struct Configuration: Sendable {
    public let apiKey: String
    public let appUserID: String?
    public let gatewayURL: URL
    public let projectID: String?

    public static func builder(withAPIKey apiKey: String) -> Builder { Builder(withAPIKey: apiKey) }

    public final class Builder {
        private let apiKey: String
        private var appUserID: String?
        private var gatewayURL = URL(string: "https://aplyna.com/api/billing")!
        private var projectID: String?
        public init(withAPIKey apiKey: String) { self.apiKey = apiKey }
        @discardableResult public func with(appUserID: String?) -> Builder { self.appUserID = appUserID; return self }
        /// Aplyna only: another billing gateway, for self-hosted or test environments.
        @discardableResult public func with(gatewayURL: URL) -> Builder { self.gatewayURL = gatewayURL; return self }
        /// Aplyna only: catalog project for legacy app-wide keys. Store-bound keys do not need it.
        @discardableResult public func with(projectID: String?) -> Builder { self.projectID = projectID; return self }
        public func build() -> Configuration { Configuration(apiKey: apiKey, appUserID: appUserID, gatewayURL: gatewayURL, projectID: projectID) }
    }
}

/// Entry point with the same names as RevenueCat's `Purchases`.
public final class Purchases: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var instance: Purchases?
    nonisolated(unsafe) private static var level: LogLevel = .info

    public static var shared: Purchases {
        lock.lock(); defer { lock.unlock() }
        guard let instance else { fatalError("Purchases has not been configured. Please call Purchases.configure()") }
        return instance
    }
    public static var isConfigured: Bool { lock.lock(); defer { lock.unlock() }; return instance != nil }
    public static var logLevel: LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return level }
        set { lock.lock(); level = newValue; lock.unlock() }
    }
    public static func canMakePayments() -> Bool { AppStore.canMakePayments }

    @discardableResult public static func configure(withAPIKey apiKey: String) -> Purchases { configure(with: Configuration.builder(withAPIKey: apiKey).build()) }
    @discardableResult public static func configure(withAPIKey apiKey: String, appUserID: String?) -> Purchases {
        configure(with: Configuration.builder(withAPIKey: apiKey).with(appUserID: appUserID).build())
    }
    @discardableResult public static func configure(with builder: Configuration.Builder) -> Purchases { configure(with: builder.build()) }
    @discardableResult public static func configure(with configuration: Configuration) -> Purchases {
        let created = Purchases(configuration)
        lock.lock(); let previous = instance; instance = created; lock.unlock()
        if let previous { Task { await previous.core.stop() } }
        Task { await created.core.start() }
        return created
    }

    let core: PurchasesCore
    private let state = NSLock()
    private var user: String
    private weak var listener: PurchasesDelegate?
    public let attribution: Attribution

    private init(_ configuration: Configuration) {
        let defaults = UserDefaults.standard, key = PurchasesCore.userKey
        let supplied = configuration.appUserID.flatMap { AppUserIDs.isValid($0) ? $0 : nil }
        let initial = supplied ?? defaults.string(forKey: key) ?? AppUserIDs.anonymous()
        defaults.set(initial, forKey: key)
        user = initial
        core = PurchasesCore(configuration: configuration, appUserID: initial)
        attribution = Attribution(core: core)
        Task { [weak self, core] in await core.onUpdate { info in Task { @MainActor in if let self { self.delegate?.purchases(self, receivedUpdated: info) } } } }
    }

    public var appUserID: String { state.lock(); defer { state.unlock() }; return user }
    public var isAnonymous: Bool { AppUserIDs.isAnonymous(appUserID) }
    private nonisolated func setUser(_ value: String) { state.withLock { user = value } }
    public var delegate: PurchasesDelegate? {
        get { state.lock(); defer { state.unlock() }; return listener }
        set { state.lock(); listener = newValue; state.unlock() }
    }

    // MARK: Offerings and products

    public func getOfferings() async throws -> Offerings { try await wrap { try await self.core.offerings() } }
    public func offerings() async throws -> Offerings { try await getOfferings() }
    public func products(_ identifiers: [String]) async -> [StoreProduct] { (try? await core.products(identifiers)) ?? [] }

    // MARK: Purchasing

    public func purchase(package: Package) async throws -> PurchaseResultData { try await purchase(product: package.storeProduct) }
    public func purchase(product: StoreProduct) async throws -> PurchaseResultData {
        do { return try await core.purchase(product) }
        catch AplynaBillingError.cancelled { return (nil, try await cachedOrEmpty(), true) }
        catch let error as StoreKitError { if case .userCancelled = error { return (nil, try await cachedOrEmpty(), true) }; throw PurchasesErrors.map(error) }
        catch { throw PurchasesErrors.map(error) }
    }
    private func cachedOrEmpty() async throws -> CustomerInfo { try await wrap { try await self.core.customerInfo(.cachedOrFetched) } }

    public func restorePurchases() async throws -> CustomerInfo { try await wrap { try await self.core.restore() } }
    public func syncPurchases() async throws -> CustomerInfo { try await wrap { try await self.core.sync() } }

    // MARK: Customer info

    public func getCustomerInfo() async throws -> CustomerInfo { try await customerInfo(fetchPolicy: .default) }
    public func customerInfo() async throws -> CustomerInfo { try await customerInfo(fetchPolicy: .default) }
    public func customerInfo(fetchPolicy: CacheFetchPolicy) async throws -> CustomerInfo { try await wrap { try await self.core.customerInfo(fetchPolicy) } }
    public var cachedCustomerInfo: CustomerInfo? { get async { await core.cached() } }
    public func invalidateCustomerInfoCache() { Task { await core.invalidate() } }
    /// Emits the current customer info and every later update.
    public var customerInfoStream: AsyncStream<CustomerInfo> {
        AsyncStream { continuation in
            let task = Task { [core] in
                let id = await core.subscribe { continuation.yield($0) }
                if let current = try? await core.customerInfo(.cachedOrFetched) { continuation.yield(current) }
                await withTaskCancellationHandler { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } } onCancel: { Task { await core.unsubscribe(id) } }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Identity

    public func logIn(_ appUserID: String) async throws -> (customerInfo: CustomerInfo, created: Bool) {
        guard AppUserIDs.isValid(appUserID) else { throw PurchasesErrors.make(.invalidAppUserIdError) }
        let result = try await wrap { try await self.core.logIn(appUserID) }
        setUser(appUserID)
        return result
    }
    public func logOut() async throws -> CustomerInfo {
        guard !isAnonymous else { throw PurchasesErrors.make(.logOutAnonymousUserError) }
        let anonymous = AppUserIDs.anonymous()
        let info = try await wrap { try await self.core.logOut(anonymous) }
        setUser(anonymous)
        return info
    }

    // MARK: Attributes (also available through `attribution`)

    public func setAttributes(_ attributes: [String: String]) { attribution.setAttributes(attributes) }
    public func setEmail(_ email: String?) { attribution.setEmail(email) }
    public func setDisplayName(_ name: String?) { attribution.setDisplayName(name) }
    public func setPhoneNumber(_ number: String?) { attribution.setPhoneNumber(number) }
    /// Sends attributes that are still waiting. Returns how many were sent.
    @discardableResult public func syncAttributesAndOfferingsIfNeeded() async throws -> Offerings {
        try await wrap { _ = try await self.core.flushAttributes(); return try await self.core.offerings(refresh: true) }
    }

    #if canImport(UIKit)
    @MainActor public func showManageSubscriptions() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else {
            throw PurchasesErrors.make(.storeProblemError, "No active window scene.")
        }
        do { try await AppStore.showManageSubscriptions(in: scene) } catch { throw PurchasesErrors.map(error) }
    }
    #endif

    // MARK: Completion-handler variants

    public func getOfferings(completion: @escaping @Sendable (Offerings?, PublicError?) -> Void) { run(completion) { try await self.getOfferings() } }
    public func getCustomerInfo(completion: @escaping @Sendable (CustomerInfo?, PublicError?) -> Void) { run(completion) { try await self.getCustomerInfo() } }
    public func restorePurchases(completion: (@Sendable (CustomerInfo?, PublicError?) -> Void)? = nil) { run(completion ?? { _, _ in }) { try await self.restorePurchases() } }
    public func syncPurchases(completion: (@Sendable (CustomerInfo?, PublicError?) -> Void)? = nil) { run(completion ?? { _, _ in }) { try await self.syncPurchases() } }
    public func logOut(completion: (@Sendable (CustomerInfo?, PublicError?) -> Void)? = nil) { run(completion ?? { _, _ in }) { try await self.logOut() } }
    public func logIn(_ appUserID: String, completion: @escaping @Sendable (CustomerInfo?, Bool, PublicError?) -> Void) {
        Task { do { let r = try await self.logIn(appUserID); await MainActor.run { completion(r.customerInfo, r.created, nil) } } catch { await MainActor.run { completion(nil, false, error as NSError) } } }
    }
    public func purchase(package: Package, completion: @escaping @Sendable (StoreTransaction?, CustomerInfo?, PublicError?, Bool) -> Void) {
        Task {
            do {
                let r = try await self.purchase(package: package)
                // RevenueCat reports a cancelled purchase to completion handlers as an error with userCancelled true.
                await MainActor.run { completion(r.transaction, r.customerInfo, r.userCancelled ? PurchasesErrors.make(.purchaseCancelledError) : nil, r.userCancelled) }
            } catch { await MainActor.run { completion(nil, nil, error as NSError, false) } }
        }
    }

    private func run<T: Sendable>(_ completion: @escaping @Sendable (T?, PublicError?) -> Void, _ work: @escaping @Sendable () async throws -> T) {
        Task { do { let value = try await work(); await MainActor.run { completion(value, nil) } } catch { await MainActor.run { completion(nil, error as NSError) } } }
    }
    private func wrap<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        do { return try await work() } catch { throw PurchasesErrors.map(error) }
    }
}

/// `Purchases.shared.attribution`, as in RevenueCat.
public final class Attribution: Sendable {
    private let core: PurchasesCore
    init(core: PurchasesCore) { self.core = core }
    /// Empty values delete the attribute. Invalid keys are ignored and logged.
    public func setAttributes(_ attributes: [String: String]) { Task { await core.setAttributes(attributes.mapValues { Optional($0) }) } }
    public func setEmail(_ email: String?) { set(SubscriberAttributes.email, email) }
    public func setDisplayName(_ name: String?) { set(SubscriberAttributes.displayName, name) }
    public func setPhoneNumber(_ number: String?) { set(SubscriberAttributes.phoneNumber, number) }
    public func setPushToken(_ token: Data?) { set(SubscriberAttributes.apnsTokens, token.map { $0.map { String(format: "%02x", $0) }.joined() }) }
    public func setPushTokenString(_ token: String?) { set(SubscriberAttributes.apnsTokens, token) }
    private func set(_ key: String, _ value: String?) { Task { await core.setAttributes([key: value]) } }
}

/// All mutable state for `Purchases`, isolated in one actor.
actor PurchasesCore {
    static var userKey: String { "com.aplyna.purchases.appUserID." + (Bundle.main.bundleIdentifier ?? "app") }
    private static var attributesKey: String { "com.aplyna.purchases.attributes." + (Bundle.main.bundleIdentifier ?? "app") }
    private static let staleAfter: TimeInterval = 5 * 60

    private let configuration: Configuration
    private var appUserID: String
    private var client: AplynaBillingClient?
    private var connecting: Task<AplynaBillingClient, Error>?
    private var cachedOfferings: Offerings?
    private var offeringsFetchedAt = Date.distantPast
    private var latest: (info: AplynaCustomerInfo, at: Date)?
    private var updates: Task<Void, Never>?
    private var listeners: [UUID: @Sendable (CustomerInfo) -> Void] = [:]
    private var delegateUpdate: (@Sendable (CustomerInfo) -> Void)?
    private var pending: [String: Pending]
    private struct Pending: Codable { let value: String?; let updatedAt: Date }

    init(configuration: Configuration, appUserID: String) {
        self.configuration = configuration; self.appUserID = appUserID
        pending = UserDefaults.standard.data(forKey: Self.attributesKey).flatMap { try? JSONDecoder().decode([String: Pending].self, from: $0) } ?? [:]
    }

    func onUpdate(_ handler: @escaping @Sendable (CustomerInfo) -> Void) { delegateUpdate = handler }
    func subscribe(_ handler: @escaping @Sendable (CustomerInfo) -> Void) -> UUID { let id = UUID(); listeners[id] = handler; return id }
    func unsubscribe(_ id: UUID) { listeners[id] = nil }

    /// Listens for renewals, approved Ask to Buy purchases and purchases made outside the app.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if Task.isCancelled { return }
                await self?.handle(result)
            }
        }
        Task { _ = try? await customerInfo(.fetchCurrent); _ = try? await flushAttributes() }
    }
    func stop() { updates?.cancel(); updates = nil; listeners = [:]; delegateUpdate = nil }

    private func handle(_ result: VerificationResult<Transaction>) async {
        // A transaction owned by another billing customer is left unfinished and untouched.
        guard let client = try? await connected(), let info = try? await client.handleTransactionUpdate(result) else { return }
        publish(info)
    }

    /// The client is created once the store environment is known, so apps never pass it.
    private func connected() async throws -> AplynaBillingClient {
        if let client { return client }
        if let connecting { return try await connecting.value }
        let configuration = self.configuration
        let task = Task { () throws -> AplynaBillingClient in
            var sandbox = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
            if case .verified(let app)? = try? await AppTransaction.shared { sandbox = app.environment != .production }
            return try AplynaBillingClient(gatewayURL: configuration.gatewayURL, sdkKey: configuration.apiKey, environment: sandbox ? .sandbox : .production)
        }
        connecting = task
        defer { connecting = nil }
        let created = try await task.value
        client = created
        return created
    }

    func offerings(refresh: Bool = false) async throws -> Offerings {
        // Offerings are reused for five minutes, then read again so catalog changes arrive.
        if let cachedOfferings, !refresh, Date().timeIntervalSince(offeringsFetchedAt) < Self.staleAfter { return cachedOfferings }
        do {
            let client = try await connected()
            let catalog = try await client.offeringsCatalog(projectID: configuration.projectID)
            let identifiers = Array(Set(catalog.offerings.flatMap(\.packages).flatMap(\.products).filter { $0.store == "apple" }.map(\.identifier)))
            let products = try await client.storeProducts(for: identifiers)
            let assembled = Offerings.assemble(catalog: catalog, products: Dictionary(products.map { ($0.id, StoreProduct(sk2Product: $0)) }, uniquingKeysWith: { first, _ in first }))
            if !identifiers.isEmpty && products.isEmpty {
                throw PurchasesErrors.make(.configurationError, "None of the products registered in the Aplyna catalog could be fetched from the App Store.")
            }
            cachedOfferings = assembled
            offeringsFetchedAt = Date()
            return assembled
        } catch {
            // A previous successful answer stays usable when the refresh fails.
            if let cachedOfferings { return cachedOfferings }
            throw error
        }
    }

    func products(_ identifiers: [String]) async throws -> [StoreProduct] {
        try await connected().storeProducts(for: identifiers).map { StoreProduct(sk2Product: $0) }
    }

    func purchase(_ product: StoreProduct) async throws -> PurchaseResultData {
        guard AppStore.canMakePayments else { throw PurchasesErrors.make(.purchaseNotAllowedError) }
        guard let native = product.sk2Product else { throw PurchasesErrors.make(.productNotAvailableForPurchaseError) }
        let client = try await connected()
        _ = try? await flushAttributes()
        let info = try await client.purchase(native)
        publish(info)
        var transaction: StoreTransaction?
        if case .verified(let value)? = await Transaction.latest(for: native.id) {
            transaction = StoreTransaction(transactionIdentifier: String(value.id), productIdentifier: value.productID, purchaseDate: value.purchaseDate)
        }
        return (transaction, CustomerInfo(info, appUserID: appUserID), false)
    }

    func restore() async throws -> CustomerInfo { publish(try await connected().restorePurchases()) }
    func sync() async throws -> CustomerInfo { publish(try await connected().syncPendingPurchases()) }

    func cached() async -> CustomerInfo? {
        if let latest { return CustomerInfo(latest.info, appUserID: appUserID) }
        guard let client = try? await connected(), let info = await client.cachedCustomerInfo() else { return nil }
        return CustomerInfo(info, appUserID: appUserID)
    }
    func invalidate() { latest = nil }

    func customerInfo(_ policy: CacheFetchPolicy) async throws -> CustomerInfo {
        let client = try await connected()
        let memory = latest
        let stored = memory?.info
        let disk = stored == nil ? await client.cachedCustomerInfo() : nil
        let known = stored ?? disk
        let fresh = memory.map { Date().timeIntervalSince($0.at) < Self.staleAfter } ?? false
        switch policy {
        case .fromCacheOnly:
            guard let known else { throw PurchasesErrors.make(.customerInfoError, "No cached customer info is available.") }
            return CustomerInfo(known, appUserID: appUserID)
        case .cachedOrFetched:
            if let known {
                if !fresh { Task { _ = try? await self.refresh() } }
                return CustomerInfo(known, appUserID: appUserID)
            }
        case .notStaleCachedOrFetched:
            if let stored, fresh { return CustomerInfo(stored, appUserID: appUserID) }
        case .fetchCurrent: break
        }
        do { return try await refresh() }
        catch {
            // Offline or server trouble: show the last verified answer instead of failing,
            // unless the caller asked for a current one. Expired entitlements stay expired.
            if policy != .fetchCurrent, let known { return CustomerInfo(known, appUserID: appUserID) }
            throw error
        }
    }
    private func refresh() async throws -> CustomerInfo { publish(try await connected().syncPendingPurchases()) }

    @discardableResult private func publish(_ info: AplynaCustomerInfo) -> CustomerInfo {
        let value = CustomerInfo(info, appUserID: appUserID)
        let previous = latest.map { CustomerInfo($0.info, appUserID: appUserID) }
        latest = (info, Date())
        if previous?.entitlements != value.entitlements || previous?.activeSubscriptions != value.activeSubscriptions || previous == nil {
            delegateUpdate?(value)
            for listener in listeners.values { listener(value) }
        }
        return value
    }

    // MARK: Identity

    /// Associates this install's purchases with the app's own user ID. `created` is true the first
    /// time this install sees the ID. Purchases stay with the device's billing customer.
    func logIn(_ id: String) async throws -> (customerInfo: CustomerInfo, created: Bool) {
        let seenKey = Self.userKey + ".seen"
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        let created = seen.insert(id).inserted
        if id != appUserID {
            appUserID = id
            UserDefaults.standard.set(id, forKey: Self.userKey)
            UserDefaults.standard.set(Array(seen), forKey: seenKey)
            pending["$appUserId"] = Pending(value: id, updatedAt: Date()); savePending()
        }
        _ = try? await flushAttributes()
        return (try await customerInfo(.fetchCurrent), created)
    }
    func logOut(_ anonymous: String) async throws -> CustomerInfo {
        _ = try? await flushAttributes()
        appUserID = anonymous
        UserDefaults.standard.set(anonymous, forKey: Self.userKey)
        pending["$appUserId"] = Pending(value: nil, updatedAt: Date()); savePending()
        // Tell the server now that this install no longer carries the user ID; a failure is retried later.
        _ = try? await flushAttributes()
        cachedOfferings = nil
        return try await customerInfo(.fetchCurrent)
    }

    // MARK: Attributes

    func setAttributes(_ attributes: [String: String?]) async {
        var changed = false
        for (key, value) in attributes where SubscriberAttributes.isValidKey(key) {
            let normalized = SubscriberAttributes.normalized(value)
            if let current = pending[key], current.value == normalized { continue }
            pending[key] = Pending(value: normalized, updatedAt: Date()); changed = true
        }
        if changed { savePending(); _ = try? await flushAttributes() }
    }
    private func savePending() {
        if let data = try? JSONEncoder().encode(pending) { UserDefaults.standard.set(data, forKey: Self.attributesKey) }
    }
    /// Unsent attributes are kept on the device and retried on the next call or launch.
    @discardableResult func flushAttributes() async throws -> Int {
        guard !pending.isEmpty else { return 0 }
        let batch = pending
        try await connected().sendAttributes(batch.mapValues { (value: $0.value, updatedAt: $0.updatedAt) }, appUserID: AppUserIDs.isAnonymous(appUserID) ? nil : appUserID)
        for (key, sent) in batch where pending[key]?.updatedAt == sent.updatedAt { pending[key] = nil }
        savePending()
        return batch.count
    }
}
