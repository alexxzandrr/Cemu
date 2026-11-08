import SwiftUI
import UIKit

/// Dual-screen layouts (iPhone Duo, also iPad): the Wii U TV image and the GamePad screen at the same time, the way a
/// Wii U is played. On iPhone Duo the arrangement follows the fold:
///
/// - folded like a laptop (fold across the screen): TV on the top half, GamePad screen with the controls on the bottom
///   half, like a handheld with two screens;
/// - folded like a book (fold down the middle): TV on one side, GamePad screen on the other, controls over both;
/// - open flat or closed: TV only, full screen, controls over it (the earlier full-screen mode). A tall screen with no
///   fold (Duo opened flat and held tall, iPad in portrait) uses the laptop layout split in the middle.
///
/// "Screens" in the toolbar overrides this (TV only / TV + GamePad).

enum ScreensSetting: String, CaseIterable, Identifiable {
    case auto, single, dual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .single: return "TV only"
        case .dual: return "TV + GamePad"
        }
    }
}

/// Where each screen and the controls go, in the root view's coordinates (full screen, safe areas ignored).
struct ScreenArrangement: Equatable {
    enum Kind: String { case single, stacked, sideBySide }
    var kind: Kind
    var tv: CGRect
    /// nil: no separate GamePad screen (the toolbar's Pad view switch shows it in the TV view instead)
    var pad: CGRect?
    /// bottom half in the stacked layout: the GamePad screen sits in it with the controls on either side
    var controlsPanel: CGRect?
    /// the fold, if the device reported one
    var fold: CGRect?

    /// One line for WiiPad.log, e.g. "stacked (fold at y 440-470), TV 626x440, GamePad 342x192".
    var logDescription: String {
        func sz(_ r: CGRect) -> String { "\(Int(r.width))x\(Int(r.height))" }
        var text = kind.rawValue
        if let fold {
            text += fold.width > fold.height ? " (fold at y \(Int(fold.minY))-\(Int(fold.maxY)))"
                                             : " (fold at x \(Int(fold.minX))-\(Int(fold.maxX)))"
        } else {
            text += " (no fold)"
        }
        text += ", TV \(sz(tv))"
        if let pad { text += ", GamePad \(sz(pad))" }
        return text
    }

    /// `insets`: safe area of the full-screen space; the controls panel stays out of it (home indicator, rounded corners).
    static func make(size: CGSize, fold: CGRect?, setting: ScreensSetting,
                     insets: EdgeInsets = EdgeInsets()) -> ScreenArrangement {
        let full = CGRect(origin: .zero, size: size)
        if setting == .single {
            return ScreenArrangement(kind: .single, tv: full, pad: nil, controlsPanel: nil, fold: fold)
        }
        if let fold, fold.width > fold.height {
            return stacked(size: size, gapTop: fold.minY, gapBottom: fold.maxY, fold: fold, insets: insets)
        }
        if let fold, fold.height > fold.width {
            return sideBySide(size: size, gapLeft: fold.minX, gapRight: fold.maxX, fold: fold)
        }
        // no fold: tall screens stack, wide ones stay single unless dual was chosen
        let tall = size.height > size.width * 1.15
        if tall {
            return stacked(size: size, gapTop: size.height / 2, gapBottom: size.height / 2, fold: nil, insets: insets)
        }
        if setting == .dual {
            return sideBySide(size: size, gapLeft: size.width / 2, gapRight: size.width / 2, fold: nil)
        }
        return ScreenArrangement(kind: .single, tv: full, pad: nil, controlsPanel: nil, fold: nil)
    }

    private static func stacked(size: CGSize, gapTop: CGFloat, gapBottom: CGFloat, fold: CGRect?,
                                insets: EdgeInsets) -> ScreenArrangement {
        let tv = CGRect(x: 0, y: 0, width: size.width, height: max(gapTop, 1))
        let panel = CGRect(x: insets.leading, y: gapBottom,
                           width: max(size.width - insets.leading - insets.trailing, 1),
                           height: max(size.height - gapBottom - insets.bottom, 1))
        let pad = DualControlsPanel.padScreenFrame(in: panel)
        return ScreenArrangement(kind: .stacked, tv: tv, pad: pad, controlsPanel: panel, fold: fold)
    }

    private static func sideBySide(size: CGSize, gapLeft: CGFloat, gapRight: CGFloat, fold: CGRect?) -> ScreenArrangement {
        let tv = CGRect(x: 0, y: 0, width: max(gapLeft, 1), height: size.height)
        let pad = CGRect(x: gapRight, y: 0, width: max(size.width - gapRight, 1), height: size.height)
        return ScreenArrangement(kind: .sideBySide, tv: tv, pad: pad, controlsPanel: nil, fold: fold)
    }
}

/// The active fold of an iPhone Duo (a "division" reserved region) in `proxy`'s coordinates, or nil when the device
/// has no fold or it is open flat / closed. Needs the iOS 27.1 SDK (Xcode 27.1).
@MainActor
func activeFold(in proxy: GeometryProxy) -> CGRect? {
    if #available(iOS 27.1, *) {
        for region in proxy.reservedRegions(kind: .division) {
            let frame = region.frame
            if frame.width > 0, frame.height > 0 { return frame }
        }
    }
    return nil
}

// MARK: - GamePad screen view

/// Hosts the CAMetalLayer Cemu draws the GamePad image into (its "separate GamePad view"). While `active` it is
/// attached to the renderer; touches on it are GamePad touchscreen input.
final class PadSurfaceView: UIView {
    var active = false {
        didSet { if active != oldValue { setNeedsLayout(); if !active { CemuBridge.shared.detachGamePadView() } } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard active, bounds.width >= 1, bounds.height >= 1 else { return }
        if CemuBridge.shared.gamePadViewAttached {
            CemuBridge.shared.gamePadViewDidResize(self)
        } else {
            CemuBridge.shared.attachGamePadView(self)
        }
    }

    private func forward(_ touches: Set<UITouch>, down: Bool) {
        guard let touch = touches.first, bounds.width > 0, bounds.height > 0 else { return }
        let p = touch.location(in: self)
        CemuBridge.shared.setGamePadViewTouchDown(down, x: Float(p.x / bounds.width), y: Float(p.y / bounds.height))
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, down: true) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, down: true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, down: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, down: false) }
}

struct PadHostView: UIViewRepresentable {
    let active: Bool

    func makeUIView(context: Context) -> PadSurfaceView {
        let view = PadSurfaceView()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = false
        return view
    }

    func updateUIView(_ view: PadSurfaceView, context: Context) {
        view.active = active
    }
}

// MARK: - Controls around the GamePad screen (stacked layout)

/// Bottom half of the stacked layout: GamePad screen in the middle, left stick and D-pad on the left, right stick and
/// X/A/B/Y on the right, shoulder buttons in the top corners, − / + under the screen. Drawn around (not over) the
/// GamePad screen, whose frame comes from `padScreenFrame(in:)`.
struct DualControlsPanel: View {
    let panel: CGRect

    /// width of each control column at the sides of the GamePad screen
    static func sideWidth(for panel: CGRect) -> CGFloat {
        min(max(panel.width * 0.23, 118), 230)
    }

    static func scale(for panel: CGRect) -> CGFloat {
        min(max(sideWidth(for: panel) / 150, 0.78), 1.4)
    }

    static func padScreenFrame(in panel: CGRect) -> CGRect {
        let side = sideWidth(for: panel)
        let s = scale(for: panel)
        let top = 52 * s       // shoulder row
        let bottom = 54 * s    // − / + and toolbar
        let maxW = max(panel.width - 2 * side - 16, 80)
        let maxH = max(panel.height - top - bottom, 45)
        var w = maxW
        var h = w * 9 / 16
        if h > maxH { h = maxH; w = h * 16 / 9 }
        return CGRect(x: panel.midX - w / 2, y: panel.minY + top + (maxH - h) / 2, width: w, height: h)
    }

    var body: some View {
        let s = Self.scale(for: panel)
        let side = Self.sideWidth(for: panel)
        let pad = Self.padScreenFrame(in: panel)
        let stick = min(side - 12, 132 * s)
        let diamond = min((side - 12) / 3, 46 * s)
        let shoulderW = min((side - 16) / 2, 70 * s), shoulderH = 40 * s

        ZStack(alignment: .topLeading) {
            // shoulders
            HStack(spacing: 8) {
                PadButton(title: "ZL", button: .zl, width: shoulderW, height: shoulderH, circle: false)
                PadButton(title: "L", button: .l, width: shoulderW, height: shoulderH, circle: false)
                Spacer()
                PadButton(title: "R", button: .r, width: shoulderW, height: shoulderH, circle: false)
                PadButton(title: "ZR", button: .zr, width: shoulderW, height: shoulderH, circle: false)
            }
            .padding(.horizontal, 8)
            .frame(width: panel.width)
            .offset(y: 6 * s)

            // left column
            VStack(spacing: 10 * s) {
                PadStick(stick: 0, diameter: stick)
                PadDiamond(top: ("▲", .up), left: ("◀", .left), right: ("▶", .right), bottom: ("▼", .down),
                           size: diamond, circle: false)
            }
            .frame(width: side)
            .offset(y: 52 * s)

            // right column
            VStack(spacing: 10 * s) {
                PadStick(stick: 1, diameter: stick)
                PadDiamond(top: ("X", .x), left: ("Y", .y), right: ("A", .a), bottom: ("B", .b), size: diamond)
            }
            .frame(width: side)
            .offset(x: panel.width - side, y: 52 * s)

            // − / + under the GamePad screen
            HStack(spacing: 24 * s) {
                PadButton(title: "−", button: .minus, width: 44 * s, height: 32 * s)
                PadButton(title: "+", button: .plus, width: 44 * s, height: 32 * s)
            }
            .frame(width: panel.width)
            .offset(y: pad.maxY - panel.minY + 10 * s)
        }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
    }
}

// MARK: - Screens menu (toolbar)

struct ScreensMenu: View {
    @Binding var setting: ScreensSetting
    let current: ScreenArrangement.Kind

    var body: some View {
        Menu {
            Picker("Screens", selection: $setting) {
                ForEach(ScreensSetting.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
        } label: {
            ToolbarLabel(systemImage: current == .single ? "rectangle" : "rectangle.split.1x2",
                         label: setting == .auto ? "Screens" : setting.title)
        }
        .onChange(of: setting) { value in
            CemuBridge.shared.log("screens setting: \(value.rawValue)")
        }
    }
}
