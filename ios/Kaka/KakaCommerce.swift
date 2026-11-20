import Foundation
import Security
@preconcurrency import StoreKit

@MainActor
final class KakaCommerce: NSObject {
    static let shared = KakaCommerce()

    private enum Issue: String, LocalizedError {
        case unavailable = "Purchases are unavailable."
        case busy = "Please wait for the current purchase."
        case response = "The store could not confirm this request."
        case storage = "Purchase records could not be saved on this device."
        case receipt = "The App Store receipt is unavailable."

        var errorDescription: String? { rawValue }
    }

    private enum Status: String {
        case idle, apple, deferred, verifying, pending, complete, failed, cancelled, restoring, restored, wrongAccount
    }

    private struct Buyer: Equatable {
        let session: UUID
        let account: Int64
        let scope: String
    }

    private struct Pack {
        let product: SKProduct
        let channelID: Int64
        let channel: String
    }

    private struct Order: Codable {
        let number: String
        let account: Int64
        let scope: String
        let productID: String
        var transaction: String?
        var receiptAccepted = false
        var credited = false

        func belongs(to buyer: Buyer) -> Bool {
            buyer.account == account && buyer.scope == scope
        }
    }

    private var buyer: Buyer?
    private var offers: [String: Pack] = [:]
    private var status = Status.idle
    private var makingOrder = false
    private var claimingReward = false
    private var restoring = false
    private var lastRecovery = Date.distantPast
    private var creditChecks: Set<String> = []
    private var productsRequest: SKProductsRequest?
    private var productsReply: CheckedContinuation<[SKProduct], Error>?
    private var receiptRequest: SKReceiptRefreshRequest?
    private var receiptReply: CheckedContinuation<Void, Error>?
    private var receiptRefresh: Task<Void, Error>?

    private override init() {
        super.init()
        SKPaymentQueue.default().add(self)
    }

    func resume(session: UUID) async {
        guard let current = try? await activate(session: session) else { return }
        checkUnfinished(current)
    }

    private func activate(session: UUID) async throws -> Buyer {
        let account = try await KakaAccountStore.shared.remoteUserID(session: session)
        let scope = try await KakaAccountStore.shared.remoteCommerceScope(session: session)
        let current = Buyer(session: session, account: account, scope: scope)
        if buyer != current {
            buyer = current
            status = .idle
            offers.removeAll()
            lastRecovery = .distantPast
        }
        return current
    }

    func perform(_ operation: String, productID: String?, session: UUID) async throws -> Data {
        let current = try await activate(session: session)
        let view: [String: Any]
        switch operation {
        case "commerce.catalog":
            view = try await catalog(current)
            checkUnfinished(current)
        case "commerce.purchase":
            guard let productID else { throw Issue.unavailable }
            try await startOrder(productID, buyer: current)
            view = ["purchaseState": status.rawValue]
        case "commerce.restore":
            guard !restoring, !makingOrder else { throw Issue.busy }
            restoring = true
            status = .restoring
            checkUnfinished(current, mayRefreshReceipt: true)
            SKPaymentQueue.default().restoreCompletedTransactions()
            view = ["purchaseState": status.rawValue]
        case "commerce.wallet":
            if status == .pending, Date().timeIntervalSince(lastRecovery) >= 5 {
                checkUnfinished(current)
            }
            let profile = try dictionary(await request("/r2/voyager/brief", buyer: current))
            guard let balance = Self.decimal(profile["starGems"]), balance >= 0 else { throw Issue.response }
            view = ["balance": NSDecimalNumber(decimal: balance).stringValue, "purchaseState": status.rawValue]
        case "commerce.rewards":
            view = try dictionary(await request("/beacon/arrival/brief", buyer: current))
        case "commerce.claimReward":
            guard !claimingReward else { throw Issue.busy }
            claimingReward = true
            defer { claimingReward = false }
            let availability = try dictionary(await request("/beacon/arrival/brief", buyer: current))
            guard Self.flag(availability["castPermit"]), !Self.flag(availability["orbitBound"]) else { throw Issue.unavailable }
            let reward = try dictionary(await request("/beacon/arrival/execute", buyer: current))
            guard Self.flag(reward["ready"]) else { throw Issue.response }
            view = reward
        case "commerce.level":
            view = try dictionary(await request("/r2/voyager/rank-brief", buyer: current))
        default:
            throw Issue.unavailable
        }
        try await ensureCurrent(current)
        return try JSONSerialization.data(withJSONObject: view)
    }

    private func catalog(_ current: Buyer) async throws -> [String: Any] {
        guard productsReply == nil else { throw Issue.busy }
        offers.removeAll()
        let response = try await request("/r2/treasury/fuel-catalog", buyer: current)
        guard let rows = Self.rows(response) else { throw Issue.response }
        let eligible = rows.prefix(128).compactMap { row -> (id: String, channel: [String: Any], diamonds: Int64, bonus: Int64, firstBonus: Int64)? in
            guard let id = row["showSequence"] as? String, !id.isEmpty, id.utf8.count <= 255,
                  let channels = row["stageLanes"] as? [[String: Any]],
                  let channel = Self.appleChannel(channels),
                  let diamonds = Self.integer(row["starGems"]), diamonds > 0 else { return nil }
            let bonus = max(0, Self.integer(row["stardustCount"]) ?? 0)
            let firstBonus = Self.flag(row["fanClaimed"]) ? 0 : max(0, Self.integer(row["debutBonus"]) ?? 0)
            return (id, channel, diamonds, bonus, firstBonus)
        }
        let ids = Set(eligible.map(\.id))
        let products = try await lookup(ids)
        try await ensureCurrent(current)
        var byID: [String: SKProduct] = [:]
        for product in products { byID[product.productIdentifier] = product }
        offers.removeAll()
        let packs: [[String: Any]] = eligible.compactMap { row in
            guard let product = byID[row.id], offers[row.id] == nil,
                  let channelID = Self.integer(row.channel["orbitMark"]), channelID > 0 else { return nil }
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.locale = product.priceLocale
            guard let price = formatter.string(from: product.price) else { return nil }
            let channel = Self.text(row.channel["voyagerChannel"])
            offers[row.id] = Pack(product: product, channelID: channelID, channel: channel)
            return ["id": row.id, "diamonds": String(row.diamonds), "bonus": String(row.bonus),
                    "firstBonus": String(row.firstBonus),
                    "price": price, "available": SKPaymentQueue.canMakePayments()]
        }
        return ["packs": packs, "missingAppleProducts": ids.subtracting(offers.keys).count]
    }

    private func startOrder(_ productID: String, buyer current: Buyer) async throws {
        guard !makingOrder, !restoring, status != .apple, status != .verifying else { throw Issue.busy }
        guard SKPaymentQueue.canMakePayments(), let pack = offers[productID] else { throw Issue.unavailable }
        let queue = SKPaymentQueue.default()
        guard !queue.transactions.contains(where: { $0.payment.productIdentifier == productID && $0.transactionState != .failed }) else {
            throw Issue.busy
        }
        _ = try loadOrders()
        makingOrder = true
        defer { makingOrder = false }
        let result = try dictionary(await request("/r2/treasury/forge-ticket", [
            "beaconStatus": 0, "cargoBrief": pack.channelID, "voyagerMark": productID,
            "transitChannel": pack.channel.isEmpty ? NSNull() as Any : pack.channel,
            "programKind": 1
        ], buyer: current))
        guard let number = result["dispatchCipher"] as? String, !number.isEmpty else { throw Issue.response }
        try await ensureCurrent(current)
        var orders = try loadOrders()
        guard !orders.contains(where: { $0.number == number }) else { throw Issue.response }
        orders.append(Order(number: number, account: current.account, scope: current.scope, productID: productID))
        try saveOrders(orders)
        let payment = SKMutablePayment(product: pack.product)
        payment.applicationUsername = number
        status = .apple
        queue.add(payment)
    }

    private func checkUnfinished(_ current: Buyer, mayRefreshReceipt: Bool = false) {
        lastRecovery = Date()
        guard buyer == current else { return }
        let queue = SKPaymentQueue.default()
        observe(queue, transactions: queue.transactions, mayRefreshReceipt: mayRefreshReceipt)
    }

    private func settle(_ transaction: SKPaymentTransaction, buyer current: Buyer, mayRefreshReceipt: Bool) async {
        guard let id = transaction.transactionIdentifier, !id.isEmpty,
              creditChecks.insert(id).inserted else { return }
        defer { creditChecks.remove(id) }
        do {
            try await ensureCurrent(current)
            let originalOrder = transaction.payment.applicationUsername ?? transaction.original?.payment.applicationUsername
            let productID = transaction.payment.productIdentifier
            guard let association = try loadOrders().first(where: {
                $0.belongs(to: current) && $0.productID == productID && ($0.number == originalOrder || $0.transaction == id)
            }) else {
                status = .wrongAccount
                return
            }
            if !association.credited {
                status = .verifying
                let number = association.number
                let alreadyCredited = if association.transaction != nil {
                    try await creditConfirmed(order: number, buyer: current)
                } else {
                    false
                }
                try revise(number) { $0.transaction = id }
                if !association.receiptAccepted && !alreadyCredited {
                    let receipt = try await appReceipt(mayRefresh: mayRefreshReceipt)
                    let callback = try JSONSerialization.data(withJSONObject: ["orderCode": number])
                    _ = try await request("/r2/treasury/confirm/lunar-acquire", [
                        "transitReceipt": id, "signalPacket": receipt.base64EncodedString(),
                        "encoreReply": String(decoding: callback, as: UTF8.self)
                    ], buyer: current)
                    try revise(number) { $0.receiptAccepted = true }
                }
                let confirmed = alreadyCredited ? true : try await creditConfirmed(order: number, buyer: current)
                guard confirmed else {
                    status = .pending
                    return
                }
                try revise(number) { $0.credited = true }
            }
            try await ensureCurrent(current)
            SKPaymentQueue.default().finishTransaction(transaction)
            status = .complete
        } catch {
            if buyer == current { status = .pending }
        }
    }

    private func creditConfirmed(order: String, buyer: Buyer) async throws -> Bool {
        let phase = try dictionary(await request("/r2/treasury/ticket-phase", ["dispatchCipher": order], buyer: buyer))
        return Self.integer(phase["signalCondition"]) == 2
    }

    private func revise(_ number: String, update: (inout Order) -> Void) throws {
        var orders = try loadOrders()
        guard let index = orders.firstIndex(where: { $0.number == number }) else { throw Issue.storage }
        update(&orders[index])
        try saveOrders(orders)
    }

    private func ensureCurrent(_ current: Buyer) async throws {
        let account = try await KakaAccountStore.shared.remoteUserID(session: current.session)
        guard buyer == current, account == current.account else { throw Issue.unavailable }
    }

    private func request(_ path: String, _ fields: [String: Any] = [:], buyer current: Buyer) async throws -> Any {
        try await ensureCurrent(current)
        let body = try JSONSerialization.data(withJSONObject: fields)
        let data = try await KakaAccountStore.shared.call(path: path, body: body, session: current.session)
        try await ensureCurrent(current)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func dictionary(_ value: Any) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else { throw Issue.response }
        return dictionary
    }

    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func integer(_ value: Any?) -> Int64? { Int64(text(value)) }
    private static func decimal(_ value: Any?) -> Decimal? {
        Decimal(string: text(value), locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func flag(_ value: Any?) -> Bool {
        ["1", "true"].contains(text(value).lowercased())
    }

    private static func rows(_ value: Any, depth: Int = 0) -> [[String: Any]]? {
        if let rows = value as? [[String: Any]] { return rows }
        guard depth < 8, let object = value as? [String: Any] else { return nil }
        for key in ["gridBands", "records", "roster", "data", "result", "nebulaPieces"] {
            if let nested = object[key], let rows = rows(nested, depth: depth + 1) { return rows }
        }
        return nil
    }

    private static func appleChannel(_ channels: [[String: Any]]) -> [String: Any]? {
        let apple = channels.filter { channel in
            let mode = text(channel["venueMode"]).uppercased()
            let name = text(channel["voyagerChannel"]).uppercased()
            return (integer(channel["orbitMark"]) ?? 0) > 0
                && (["IOS", "7"].contains(mode) || name.contains("APPLE_IAP") || name == "IAP")
        }
        return apple.first { flag($0["freshOrbit"]) } ?? apple.first { flag($0["openingPick"]) } ?? apple.first
    }

    private func lookup(_ identifiers: Set<String>) async throws -> [SKProduct] {
        guard !identifiers.isEmpty else { return [] }
        guard productsReply == nil else { throw Issue.busy }
        return try await withCheckedThrowingContinuation { continuation in
            let request = SKProductsRequest(productIdentifiers: identifiers)
            productsRequest = request
            productsReply = continuation
            request.delegate = self
            request.start()
        }
    }

    private func appReceipt(mayRefresh: Bool) async throws -> Data {
        if let data = existingReceipt() { return data }
        guard mayRefresh else { throw Issue.receipt }
        let running: Task<Void, Error>
        if let receiptRefresh {
            running = receiptRefresh
        } else {
            running = Task { @MainActor in
                defer { self.receiptRefresh = nil }
                try await withCheckedThrowingContinuation { continuation in
                    let request = SKReceiptRefreshRequest()
                    self.receiptRequest = request
                    self.receiptReply = continuation
                    request.delegate = self
                    request.start()
                }
            }
            receiptRefresh = running
        }
        try await running.value
        guard let data = existingReceipt() else { throw Issue.receipt }
        return data
    }

    private func existingReceipt() -> Data? {
        guard let url = Bundle.main.appStoreReceiptURL, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    private var ledger: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Kaka") + ".commerce.orders.v1",
         kSecAttrAccount as String: "storekit"]
    }

    private func loadOrders() throws -> [Order] {
        var query = ledger
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return [] }
        guard code == errSecSuccess, let data = result as? Data else { throw Issue.storage }
        return try JSONDecoder().decode([Order].self, from: data)
    }

    private func saveOrders(_ orders: [Order]) throws {
        let data = try JSONEncoder().encode(orders)
        let code = SecItemUpdate(ledger as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if code == errSecItemNotFound {
            var item = ledger
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Issue.storage }
        } else if code != errSecSuccess {
            throw Issue.storage
        }
    }

    private func observe(_ queue: SKPaymentQueue, transactions: [SKPaymentTransaction], mayRefreshReceipt: Bool) {
        for transaction in transactions {
            switch transaction.transactionState {
            case .purchased, .restored:
                if let buyer { Task { await self.settle(transaction, buyer: buyer, mayRefreshReceipt: mayRefreshReceipt) } }
            case .failed:
                if let buyer, let number = transaction.payment.applicationUsername,
                   let orders = try? loadOrders(), orders.contains(where: { $0.number == number && $0.belongs(to: buyer) }) {
                    status = (transaction.error as? SKError)?.code == .paymentCancelled ? .cancelled : .failed
                }
                queue.finishTransaction(transaction)
            case .deferred, .purchasing:
                if let buyer, let number = transaction.payment.applicationUsername,
                   let orders = try? loadOrders(), orders.contains(where: { $0.number == number && $0.belongs(to: buyer) }) {
                    status = transaction.transactionState == .deferred ? .deferred : .apple
                }
            @unknown default:
                break
            }
        }
    }
}

extension KakaCommerce: SKPaymentTransactionObserver, SKProductsRequestDelegate {
    nonisolated func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        Task { @MainActor in
            self.observe(queue, transactions: transactions, mayRefreshReceipt: self.restoring || self.status == .apple)
        }
    }

    nonisolated func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        Task { @MainActor in
            self.restoring = false
            if self.status == .restoring { self.status = .restored }
            if let buyer = self.buyer { self.checkUnfinished(buyer) }
        }
    }

    nonisolated func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
        Task { @MainActor in
            self.restoring = false
            if self.status == .restoring {
                self.status = (error as? SKError)?.code == .paymentCancelled ? .cancelled : .failed
            }
        }
    }

    nonisolated func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        Task { @MainActor in
            guard self.productsRequest === request else { return }
            let reply = self.productsReply
            self.productsReply = nil
            self.productsRequest = nil
            reply?.resume(returning: response.products)
        }
    }

    nonisolated func requestDidFinish(_ request: SKRequest) {
        Task { @MainActor in
            guard self.receiptRequest === request else { return }
            let reply = self.receiptReply
            self.receiptReply = nil
            self.receiptRequest = nil
            reply?.resume()
        }
    }

    nonisolated func request(_ request: SKRequest, didFailWithError error: Error) {
        Task { @MainActor in
            if self.productsRequest === request {
                let reply = self.productsReply
                self.productsReply = nil
                self.productsRequest = nil
                reply?.resume(throwing: Issue.unavailable)
            } else if self.receiptRequest === request {
                let reply = self.receiptReply
                self.receiptReply = nil
                self.receiptRequest = nil
                reply?.resume(throwing: Issue.receipt)
            }
        }
    }
}
