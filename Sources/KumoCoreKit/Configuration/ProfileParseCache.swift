import Foundation

/// Cheap on-disk identity of the file a profile read resolves to.
///
/// Comparing identities lets a caller prove a profile body has not changed
/// without reading it again.
public struct ProfileFileIdentity: Equatable, Sendable {
    /// The file that would be read, or `nil` when the inline default profile is
    /// served instead of a file.
    public let fileURL: URL?
    public let modificationDate: Date?
    public let fileSize: Int?

    public init(fileURL: URL?, modificationDate: Date?, fileSize: Int?) {
        self.fileURL = fileURL
        self.modificationDate = modificationDate
        self.fileSize = fileSize
    }

    /// The inline default profile. Its body is a constant, so it never
    /// invalidates.
    public static let inlineDefault = ProfileFileIdentity(fileURL: nil, modificationDate: nil, fileSize: nil)

    /// Whether this identity can key a cache entry. The inline default can; a
    /// file needs both a modification date and a size, otherwise a content
    /// change could slip through unnoticed.
    var isCacheable: Bool {
        fileURL == nil || (modificationDate != nil && fileSize != nil)
    }
}

/// Memoizes the parsed views of a profile YAML — outbound nodes and proxy
/// groups — keyed by the on-disk identity of the file the read resolved to.
///
/// Both parses walk the whole document with Yams, and the app asked for them
/// repeatedly for the same unchanged file: one `loadProxyGroups()` reads the
/// current profile for the sidebar preview, for the cached-country pass and for
/// the country-detection pass, and the 60 s profile poll adds another round.
/// Invalidation is by key change only, so a profile written to disk is re-parsed
/// on the next lookup.
///
/// An actor because the memo is mutable state and every caller is already
/// async; it also keeps the Yams parse off whichever actor called in.
public actor ProfileParseCache {
    private let profiles: ProfileRepository

    private struct Entry<Value> {
        let identity: ProfileFileIdentity
        let value: Value
    }

    private var proxyGroupEntries: [String: Entry<[ProxyGroup]>] = [:]
    private var nodeEntries: [String: Entry<[String: ProfileNodeInfo]>] = [:]

    public init(profiles: ProfileRepository) {
        self.profiles = profiles
    }

    /// Proxy groups parsed from the profile's `proxy-groups:` section.
    public func proxyGroups(profileID: String) throws -> [ProxyGroup] {
        let identity = profiles.profileFileIdentity(id: profileID)
        if let entry = proxyGroupEntries[profileID], entry.identity == identity {
            return entry.value
        }
        let groups = try ProfileNodeParser.parseProxyGroups(yaml: try profileYAML(id: profileID))
        if identity.isCacheable {
            proxyGroupEntries[profileID] = Entry(identity: identity, value: groups)
        }
        return groups
    }

    /// Outbound nodes parsed from the profile's `proxies:` section.
    public func nodes(profileID: String) throws -> [String: ProfileNodeInfo] {
        let identity = profiles.profileFileIdentity(id: profileID)
        if let entry = nodeEntries[profileID], entry.identity == identity {
            return entry.value
        }
        let nodes = try ProfileNodeParser.parseNodes(yaml: try profileYAML(id: profileID))
        if identity.isCacheable {
            nodeEntries[profileID] = Entry(identity: identity, value: nodes)
        }
        return nodes
    }

    /// Reads the body through `loadProfile` so the fallback chain — the profile
    /// file, then the default profile, then the inline default — lives in exactly
    /// one place and the cache never reimplements it.
    private func profileYAML(id: String) throws -> String {
        try profiles.loadProfile(id: id).rawYAML
    }
}
