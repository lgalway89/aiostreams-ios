import SwiftUI
import UIKit

/// Ambient mode, as Nuvio has it: after a few idle minutes outside the player, the titles on Home
/// pass by full screen, art drifting slowly, until any press. It keeps the Apple TV awake for an
/// hour at most, then lets the system's own screensaver and sleep take over again.
@MainActor
final class Ambient: ObservableObject {
    static let shared = Ambient()

    @Published private(set) var showing = false
    /// Titles with art to show, from Home's rows.
    var pool: [Item] = []
    /// This showing's order.
    private(set) var reel: [Item] = []
    /// Idle minutes before it shows; 0 is off.
    var minutes = 5
    private var lastInput = Date()
    private var shownAt: Date?
    private var holds = 0
    private var timer: Timer?
    private var keptAwake = false

    /// The longest it keeps the Apple TV from sleeping.
    private static let awakeLimit: TimeInterval = 3600

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in Ambient.shared.tick() }
        }
    }

    /// Any press or touch on the remote. True when it only woke ambient mode, which then takes it.
    func input() -> Bool {
        lastInput = Date()
        guard showing else { return false }
        dismiss()
        return true
    }

    /// The player, while it's open, keeps ambient mode away.
    func hold(_ on: Bool) {
        holds = max(0, holds + (on ? 1 : -1))
        lastInput = Date()
        if on, showing { dismiss() }
    }

    private func tick() {
        if showing {
            if keptAwake, let shownAt, Date().timeIntervalSince(shownAt) > Self.awakeLimit {
                UIApplication.shared.isIdleTimerDisabled = false
                keptAwake = false
            }
            return
        }
        guard minutes > 0, holds == 0, pool.count >= 3,
              UIApplication.shared.applicationState == .active,
              Date().timeIntervalSince(lastInput) >= Double(minutes * 60) else { return }
        reel = pool.shuffled()
        withAnimation(.easeInOut(duration: 1.2)) { showing = true }
        shownAt = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        keptAwake = true
        AppLog.info("ambient", "showing \(pool.count) titles")
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.4)) { showing = false }
        shownAt = nil
        if keptAwake { UIApplication.shared.isIdleTimerDisabled = false }
        keptAwake = false
    }
}

/// Sees every press and touch on the remote without taking it, except the one that wakes ambient mode.
private final class RemoteActivityRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
        allowedPressTypes = [UIPress.PressType.select, .menu, .playPause, .upArrow, .downArrow, .leftArrow, .rightArrow]
            .map { NSNumber(value: $0.rawValue) }
    }

    private func saw() {
        if Ambient.shared.input() {
            // This press only wakes the screen: nothing behind it opens or goes back.
            cancelsTouchesInView = true
            state = .recognized
        } else {
            cancelsTouchesInView = false
            state = .failed
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) { saw() }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { saw() }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        _ = Ambient.shared.input()
        if state == .possible { state = .failed }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Puts the recognizer on the app's window once.
private struct RemoteActivityInstaller: UIViewRepresentable {
    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, !(window.gestureRecognizers ?? []).contains(where: { $0 is RemoteActivityRecognizer }) else { return }
            window.addGestureRecognizer(RemoteActivityRecognizer(target: nil, action: nil))
        }
    }

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {}
}

/// The titles going by, one every 12 seconds.
private struct AmbientView: View {
    @EnvironmentObject private var session: Session
    let items: [Item]
    @State private var index = 0
    @State private var zoomed = false
    @State private var now = Date()

    private var item: Item { items[index % items.count] }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let url = session.client?.backdrop(item, height: 1080) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.black
                    }
                }
                .scaleEffect(zoomed ? 1.08 : 1.0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .id(item.id)
                .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .clear],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
            VStack(alignment: .leading, spacing: Theme.px(14)) {
                TitleLogo(item: item, maxHeight: Theme.px(120), maxWidth: Theme.px(440), titleSize: 52)
                HeroMeta(item: item)
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray200)
                        .lineLimit(3)
                        .frame(maxWidth: Theme.px(760), alignment: .leading)
                }
            }
            .id("text-\(item.id)")
            .transition(.opacity)
            .padding(.leading, Theme.px(96))
            .padding(.bottom, Theme.px(84))
        }
        .overlay(alignment: .topTrailing) {
            Text(now, style: .time)
                .font(Theme.font(Theme.xl, .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(Theme.px(72))
        }
        .ignoresSafeArea()
        .task {
            drift()
            while !Task.isCancelled {
                // The next picture fetched ahead, so it fades in whole.
                if let next = session.client?.backdrop(items[(index + 1) % items.count], height: 1080) {
                    _ = try? await URLSession.shared.data(from: next)
                }
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                now = Date()
                zoomed = false
                withAnimation(.easeInOut(duration: 1.5)) { index += 1 }
                drift()
            }
        }
    }

    private func drift() {
        withAnimation(.linear(duration: 13)) { zoomed = true }
    }
}

extension View {
    /// Watches the remote for idleness and shows ambient mode over the app when it comes.
    func ambientMode() -> some View {
        modifier(AmbientModifier())
    }
}

private struct AmbientModifier: ViewModifier {
    @ObservedObject private var ambient = Ambient.shared
    @EnvironmentObject private var prefs: Preferences

    func body(content: Content) -> some View {
        content
            .background(RemoteActivityInstaller().frame(width: 0, height: 0))
            .overlay {
                if ambient.showing, !ambient.reel.isEmpty {
                    AmbientView(items: ambient.reel)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .onAppear {
                ambient.minutes = prefs.ambientMinutes
                ambient.start()
            }
            .onChange(of: prefs.ambientMinutes) { _, minutes in ambient.minutes = minutes }
    }
}
