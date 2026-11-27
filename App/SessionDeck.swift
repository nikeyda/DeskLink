import SwiftUI

enum DeskSplitControls: String, CaseIterable {
    case sideBySide
    case laptop

    var title: LocalizedStringKey {
        switch self {
        case .sideBySide: "左右分栏"
        case .laptop: "键盘与触控板"
        }
    }
}

struct DeskSessionDeck: Equatable {
    let divider: CGFloat
    let size: CGSize
    var gap: CGFloat = 0
    var coverMargins: EdgeInsets?

    var isCover: Bool { coverMargins != nil }
}
