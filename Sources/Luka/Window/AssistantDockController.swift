import AppKit
import LukaCore
import SwiftUI

/// A small button on the right edge of the screen while Luka listens, and the panel it opens:
/// the summary and the answers, floating over whatever app is in front, full-screen ones included.
@MainActor
final class AssistantDockController: NSObject {
    nonisolated static let buttonSize = NSSize(width: 38, height: 86)
    static let popupSize = NSSize(width: 380, height: 540)
    static let edgeInset: CGFloat = 6

    private let model: AppModel
    private let button: CaptionPanel
    private let popup: CaptionPanel
    private var drag: (mouse: NSPoint, frame: NSRect, moved: Bool)?

    init(model: AppModel) {
        self.model = model
        button = Self.makePanel(title: "Luka Assistant Button", shadow: false)
        popup = Self.makePanel(title: "Luka Assistant", shadow: true)
        super.init()

        let buttonHost = NSHostingView(rootView: LocalizedRoot {
            DockButton(onChanged: { [weak self] in self?.dragChanged() }, onEnded: { [weak self] in self?.dragEnded(top: $0) })
        }.environment(model))
        buttonHost.sizingOptions = []
        button.contentView = buttonHost

        let popupHost = NSHostingView(rootView: LocalizedRoot { DockPopup() }.environment(model))
        popupHost.sizingOptions = []
        popup.contentView = popupHost

        button.setFrame(initialButtonFrame(), display: false)
        observe()
        apply()
    }

    private static func makePanel(title: String, shadow: Bool) -> CaptionPanel {
        let panel = CaptionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = shadow
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = title
        return panel
    }

    // MARK: Frames

    private var screen: NSScreen { button.screen ?? NSScreen.main ?? NSScreen.screens[0] }

    /// On the right edge, at the height it was last left at (kept as a fraction, so it survives a screen change).
    private func initialButtonFrame() -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let fraction = UserDefaults.standard.object(forKey: "dockButtonY") as? Double ?? 0.55
        let y = visible.minY + (visible.height - Self.buttonSize.height) * CGFloat(min(max(fraction, 0), 1))
        return NSRect(x: visible.maxX - Self.buttonSize.width - Self.edgeInset, y: y,
                      width: Self.buttonSize.width, height: Self.buttonSize.height)
    }

    /// Beside the button, centered on it as far as the screen allows.
    private func popupFrame() -> NSRect {
        let visible = screen.visibleFrame
        let b = button.frame
        let size = NSSize(width: min(Self.popupSize.width, visible.width - b.width - 40),
                          height: min(Self.popupSize.height, visible.height - 24))
        let y = min(max(b.midY - size.height / 2, visible.minY + 12), visible.maxY - size.height - 12)
        return NSRect(x: b.minX - 10 - size.width, y: y, width: size.width, height: size.height)
    }

    // MARK: Showing

    private func observe() {
        withObservationTracking {
            _ = model.status
            _ = model.showsDockButton
            _ = model.dockOpen
            _ = model.captionStyle
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.apply()
                self?.observe()
            }
        }
    }

    private var buttonShown = false
    private var popupShown = false

    private func apply() {
        // Match the captions: with the Dark style the card and its controls are dark too.
        popup.appearance = model.captionStyle == .dark ? NSAppearance(named: .darkAqua) : nil
        let wanted = model.showsDockButton && model.status != .idle
        if wanted != buttonShown {
            buttonShown = wanted
            fade(button, in: wanted)
        }
        if !wanted, model.dockOpen { model.dockOpen = false }
        let open = wanted && model.dockOpen
        if open {
            popup.setFrame(popupFrame(), display: true)
            if model.dockBadge { model.dockBadge = false }
        }
        if open != popupShown {
            popupShown = open
            fade(popup, in: open)
        }
    }

    private func fade(_ panel: NSPanel, in showing: Bool) {
        if showing {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    // Shown again while fading out: leave it up.
                    let stillHidden = panel === self.button ? !self.buttonShown : !self.popupShown
                    if stillHidden { panel.orderOut(nil) }
                }
            }
        }
    }

    // MARK: Click and drag

    /// The button moves with the mouse, so the gesture's own offsets shift under it; the screen position doesn't.
    private func dragChanged() {
        let mouse = NSEvent.mouseLocation
        guard var d = drag else {
            drag = (mouse, button.frame, false)
            return
        }
        let dy = mouse.y - d.mouse.y
        if abs(dy) > 4 { d.moved = true }
        drag = d
        guard d.moved else { return }
        let visible = screen.visibleFrame
        var frame = d.frame
        frame.origin.y = min(max(d.frame.minY + dy, visible.minY + 8), visible.maxY - frame.height - 8)
        button.setFrame(frame, display: true)
        if popup.isVisible { popup.setFrame(popupFrame(), display: true) }
    }

    /// `top` says which half was pressed: the top opens the summary and answers, the bottom shows or hides captions.
    private func dragEnded(top: Bool) {
        defer { drag = nil }
        guard let d = drag, d.moved else {
            // A press without movement is a click.
            if top { model.dockOpen.toggle() } else { model.setCaptions(!model.captionsVisible) }
            return
        }
        let visible = screen.visibleFrame
        let range = max(1, visible.height - button.frame.height)
        UserDefaults.standard.set(Double((button.frame.minY - visible.minY) / range), forKey: "dockButtonY")
    }
}

/// The edge button: three dots that move with the sound while listening, and a mark when an answer is waiting.
private struct DockButton: View {
    @Environment(AppModel.self) private var model
    let onChanged: () -> Void
    /// Called with whether the press started in the top half.
    let onEnded: (Bool) -> Void

    private enum Half { case top, bottom }
    @State private var hovered: Half?

    var body: some View {
        let live = model.status == .live
        let captions = model.captionsVisible
        VStack(spacing: 0) {
            // Top half: the summary and answers.
            Image(systemName: model.dockOpen ? "chevron.right" : "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 36)
                .background(.white.opacity(hovered == .top ? 0.14 : 0))
                .help(tr("Summary and answers · drag to move"))
            Rectangle().fill(.white.opacity(0.18)).frame(width: 14, height: 0.5)
            // Bottom half: the caption strip. Three dots that move with the sound; hollow when captions are hidden.
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    let color = live ? Color.green : Color.white.opacity(0.45)
                    Capsule()
                        .fill(captions ? color : .clear)
                        .overlay { Capsule().strokeBorder(color, lineWidth: captions ? 0 : 1) }
                        .frame(width: captions ? 3 : 4,
                               height: captions ? 3 + (live ? CGFloat(model.level) * (i == 1 ? 9 : 6) : 0) : 4)
                }
            }
            .frame(width: 28, height: 35.5)
            .background(.white.opacity(hovered == .bottom ? 0.14 : 0))
            .animation(.smooth(duration: 0.18), value: model.level)
            .help(captions ? tr("Hide captions") : tr("Show captions"))
        }
        .frame(width: 28, height: 72)
        .clipShape(.capsule)
        // Dark on any background, like the system's own floating controls.
        .background(.black.opacity(hovered != nil || model.dockOpen ? 0.72 : 0.55), in: .capsule)
        .background(.ultraThinMaterial, in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        .overlay(alignment: .topTrailing) {
            if model.dockBadge {
                Circle().fill(.red).frame(width: 7, height: 7).offset(x: 1, y: -1)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.15), value: hovered)
        .animation(.smooth, value: model.dockBadge)
        .animation(.smooth(duration: 0.2), value: captions)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): hovered = point.y < AssistantDockController.buttonSize.height / 2 ? .top : .bottom
            case .ended: hovered = nil
            }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { _ in onChanged() }
            .onEnded { value in onEnded(value.startLocation.y < AssistantDockController.buttonSize.height / 2) })
    }
}

/// The summary and answers column, as a floating card.
private struct DockPopup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = model.captionStyle == .dark
        SummaryPanel(transcript: model.transcript)
            .id(model.cjkFontFamily)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // Same black and opacity as the Dark caption window.
                if dark {
                    RoundedRectangle(cornerRadius: 16).fill(.black.opacity(model.captionBackgroundOpacity))
                } else {
                    RoundedRectangle(cornerRadius: 16).fill(.regularMaterial)
                }
            }
            .clipShape(.rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(dark ? AnyShapeStyle(.white.opacity(0.08)) : AnyShapeStyle(.separator))
            }
            .environment(\.colorScheme, dark ? .dark : colorScheme)
            .environment(\.fontFamily, model.fontFamily)
            .environment(\.usesGlass, model.usesGlass)
    }
}
