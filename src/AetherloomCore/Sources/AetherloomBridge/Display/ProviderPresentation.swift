import AetherloomCore
import Foundation

public enum ProviderPalette: Sendable, Hashable {
    case iCloud
    case google
    case oneDrive
    case dropbox
    case local
    case nas
}

public struct ProviderPresentation: Sendable, Hashable {
    public var kind: ProviderKind
    public var displayName: String
    public var symbolName: String
    public var paletteToken: ProviderPalette

    public init(
        kind: ProviderKind,
        displayName: String,
        symbolName: String,
        paletteToken: ProviderPalette
    ) {
        self.kind = kind
        self.displayName = displayName
        self.symbolName = symbolName
        self.paletteToken = paletteToken
    }
}

public extension ProviderKind {
    var presentation: ProviderPresentation {
        switch self {
        case .iCloudDrive:
            ProviderPresentation(kind: self, displayName: displayName, symbolName: "icloud.fill", paletteToken: .iCloud)
        case .googleDrive:
            ProviderPresentation(kind: self, displayName: displayName, symbolName: "triangle.fill", paletteToken: .google)
        case .oneDrive:
            ProviderPresentation(kind: self, displayName: displayName, symbolName: "cloud.fill", paletteToken: .oneDrive)
        case .dropbox:
            ProviderPresentation(kind: self, displayName: displayName, symbolName: "shippingbox.fill", paletteToken: .dropbox)
        case .localFolder:
            ProviderPresentation(kind: self, displayName: displayName, symbolName: "internaldrive.fill", paletteToken: .local)
        case .nasFolder:
            ProviderPresentation(kind: self, displayName: displayName, symbolName: "server.rack", paletteToken: .nas)
        }
    }
}
