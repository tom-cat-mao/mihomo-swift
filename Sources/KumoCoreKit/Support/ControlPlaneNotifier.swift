import Foundation

public enum ControlPlaneChangeDomain: String, Codable, Sendable, CaseIterable, Hashable {
    case status
    case profiles
    case overrides
    case preferences
    case rollbacks
    case all
}

public struct ControlPlaneChangeNotification: Equatable, Sendable {
    public let senderPID: Int32
    public let domains: Set<ControlPlaneChangeDomain>
    public let appSupportPath: String?

    public init(
        senderPID: Int32,
        domains: Set<ControlPlaneChangeDomain>,
        appSupportPath: String? = nil
    ) {
        self.senderPID = senderPID
        self.domains = domains
        self.appSupportPath = appSupportPath
    }
}

public final class ControlPlaneNotifier: @unchecked Sendable {
    public static let notificationName = Notification.Name("io.kumo.controlPlaneDidChange")
    public static let shared = ControlPlaneNotifier()

    private enum UserInfoKey {
        static let senderPID = "senderPID"
        static let domains = "domains"
        static let appSupportPath = "appSupportPath"
    }

    private let center: DistributedNotificationCenter

    public init(center: DistributedNotificationCenter = .default()) {
        self.center = center
    }

    public func post(
        domains: Set<ControlPlaneChangeDomain>,
        appSupportPath: String? = nil,
        senderPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        guard !domains.isEmpty else { return }

        var userInfo: [AnyHashable: Any] = [
            UserInfoKey.senderPID: senderPID,
            UserInfoKey.domains: domains.map(\.rawValue).sorted()
        ]
        if let appSupportPath {
            userInfo[UserInfoKey.appSupportPath] = appSupportPath
        }

        center.postNotificationName(
            Self.notificationName,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    public func parse(_ notification: Notification) -> ControlPlaneChangeNotification? {
        Self.parse(notification)
    }

    public static func parse(_ notification: Notification) -> ControlPlaneChangeNotification? {
        guard notification.name == notificationName,
              let userInfo = notification.userInfo else {
            return nil
        }

        let senderPID: Int32
        if let pid = userInfo[UserInfoKey.senderPID] as? Int32 {
            senderPID = pid
        } else if let number = userInfo[UserInfoKey.senderPID] as? NSNumber {
            senderPID = number.int32Value
        } else {
            return nil
        }

        guard let rawDomains = userInfo[UserInfoKey.domains] as? [String] else {
            return nil
        }
        let domains = Set(rawDomains.compactMap(ControlPlaneChangeDomain.init(rawValue:)))
        guard !domains.isEmpty else {
            return nil
        }

        let appSupportPath = userInfo[UserInfoKey.appSupportPath] as? String
        return ControlPlaneChangeNotification(
            senderPID: senderPID,
            domains: domains,
            appSupportPath: appSupportPath
        )
    }

    public func observe(
        handler: @escaping @Sendable (ControlPlaneChangeNotification) -> Void
    ) -> NSObjectProtocol {
        center.addObserver(
            forName: Self.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            guard let parsed = Self.parse(notification) else { return }
            handler(parsed)
        }
    }

    public func removeObserver(_ token: Any) {
        center.removeObserver(token)
    }
}
