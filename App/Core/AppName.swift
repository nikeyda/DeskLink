import Foundation

enum AppName {
    static let display = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? "Telescope"
}
