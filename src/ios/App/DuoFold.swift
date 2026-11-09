// SPDX-License-Identifier: MPL-2.0
// WiiPad (2026): iPhone Duo fold support, added to the EspressU-based app.

import SwiftUI

/// The active fold of an iPhone Duo (a "division" reserved region) in `proxy`'s coordinates, or nil when the
/// device has no fold, or it is open flat or closed. The API needs the iOS 27.1 SDK.
@MainActor
func duoActiveFold(in proxy: GeometryProxy) -> CGRect? {
    if #available(iOS 27.1, *) {
        for region in proxy.reservedRegions(kind: .division) {
            let frame = region.frame
            if frame.width > 0, frame.height > 0 { return frame }
        }
    }
    return nil
}

enum DuoFoldPose: Equatable {
    /// Fold across the screen, like a laptop: TV on top, GamePad and controls below.
    case laptop(CGRect)
    /// Fold down the middle, like a book: TV on one side, GamePad on the other.
    case book(CGRect)

    init?(fold: CGRect?) {
        guard let fold else { return nil }
        self = fold.width >= fold.height ? .laptop(fold) : .book(fold)
    }

    var fold: CGRect {
        switch self {
        case .laptop(let f), .book(let f): return f
        }
    }
}

enum DuoSettings {
    /// When on (default), a half-folded iPhone Duo shows the TV and the GamePad screen split at the fold.
    static let foldLayoutKey = "wiipad.duo.foldLayout"
    static let defaultFoldLayout = true
    /// When on (default), folding the Duo shut pauses the game and opening it resumes.
    static let pauseOnCloseKey = "wiipad.duo.pauseOnClose"
    static let defaultPauseOnClose = true
}

/// Calls `onClosedChange(true)` when an iPhone Duo is folded shut and `false` when it opens again.
/// Devices without a hinge never call it.
struct DuoHingeObserver: ViewModifier {
    let onClosedChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                onClosedChange(context.hinge?.status == .closed)
            }
        } else {
            content
        }
    }
}

extension View {
    func onDuoClosedChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(DuoHingeObserver(onClosedChange: action))
    }
}
