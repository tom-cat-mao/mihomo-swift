import Foundation

public struct RuntimeOverride: Equatable, Sendable {
    public var name: String
    public var format: OverrideFormat
    public var content: String

    public init(name: String, format: OverrideFormat, content: String) {
        self.name = name
        self.format = format
        self.content = content
    }
}
