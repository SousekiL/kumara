import AppKit
import LukaCore
import SwiftUI

/// A small button on the right edge of the screen while Luka listens, and the panel it opens:
/// the summary and the answers, floating over whatever app is in front, full-screen ones included.
@MainActor
final class AssistantDockController: NSObject {
    static let buttonSize = NSSize(width: 36, height: 70)
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
            DockButton(onChanged: { [weak self] in self?.dragChanged() }, onEnded: { [weak self] in self?.dragEnded() })
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
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.apply()
                self?.observe()
            }
        }
    }

    private func apply() {
        let wanted = model.showsDockButton && model.status != .idle
        if wanted {
            if !button.isVisible { fade(button, in: true) }
        } else {
            if button.isVisible { fade(button, in: false) }
            if model.dockOpen { model.dockOpen = false }
        }
        let open = wanted && model.dockOpen
        if open {
            popup.setFrame(popupFrame(), display: true)
            if !popup.isVisible { fade(popup, in: true) }
            if model.dockBadge { model.dockBadge = false }
        } else if popup.isVisible {
            fade(popup, in: false)
        }
    }

    private func fade(_ panel: NSPanel, in showing: Bool) {
        if showing {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    // Shown again meanwhile: leave it.
                    if panel.alphaValue == 0 { panel.orderOut(nil) }
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

    private func dragEnded() {
        defer { drag = nil }
        guard let d = drag, d.moved else {
            // A press without movement is a click.
            model.dockOpen.toggle()
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
    let onEnded: () -> Void

    @State private var hovering = false

    var body: some View {
        let live = model.status == .live
        VStack(spacing: 9) {
            Image(systemName: model.dockOpen ? "chevron.right" : "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 14)
            // Three dots that stretch with the sound; still and grey when paused.
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(live ? Color.green : Color.white.opacity(0.35))
                        .frame(width: 3, height: 3 + (live ? CGFloat(model.level) * (i == 1 ? 9 : 6) : 0))
                }
            }
            .frame(width: 18, height: 12)
            .animation(.smooth(duration: 0.18), value: model.level)
        }
        .frame(width: 26, height: 56)
        // Dark on any background, like the system's own floating controls.
        .background(.black.opacity(hovering || model.dockOpen ? 0.72 : 0.55), in: .capsule)
        .background(.ultraThinMaterial, in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        .overlay(alignment: .topTrailing) {
            if model.dockBadge {
                Circle().fill(.red).frame(width: 7, height: 7).offset(x: 1, y: -1)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(.smooth(duration: 0.2), value: hovering)
        .animation(.smooth, value: model.dockBadge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { _ in onChanged() }
            .onEnded { _ in onEnded() })
        .help(tr("Summary and answers · drag to move"))
    }
}

/// The summary and answers column, as a floating card.
private struct DockPopup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SummaryPanel(transcript: model.transcript)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .clipShape(.rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator) }
            .environment(\.fontFamily, model.fontFamily)
            .environment(\.usesGlass, model.usesGlass)
    }
}
