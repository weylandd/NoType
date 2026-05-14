import SwiftUI

/// Compact banner that surfaces a pending Sparkle update inside the
/// main window's sidebar (below the nav items). Renders in lockstep
/// with `UpdateController.phase`:
///
/// - `.idle` / `.checking` / `.failed` → hidden entirely (no chrome
///    flash on transient states).
/// - `.available` → "Relaunch to update" + `vX.Y.Z` subtitle, with a
///    trailing arrow as the click affordance. Click triggers the
///    download.
/// - `.downloading(p)` → "Downloading update" + percent + progress bar.
/// - `.extracting(p)` → "Preparing update" + percent + progress bar.
/// - `.installing` → "Installing…" + indeterminate bar; the app will
///    relaunch on its own.
///
/// Surface chrome is a neutral `bgSurface` card with `borderSubtle`
/// (mirrors the calm "we have an update for you" treatment in apps
/// like Claude Desktop) — the accent shows up only on the pulse dot,
/// progress fill, and hover state.
struct UpdateBanner: View {
    @Environment(UpdateController.self) private var updates

    var body: some View {
        Group {
            switch updates.phase {
            case .idle, .checking, .failed:
                EmptyView()
            case let .available(update):
                BannerShell(
                    title: "Relaunch to update",
                    subtitle: "v\(update.versionString)",
                    progress: nil,
                    showsTrailingArrow: true,
                    onClick: { updates.installNow() }
                )
            case let .downloading(progress):
                BannerShell(
                    title: "Downloading update",
                    subtitle: progress > 0
                        ? "\(Int(progress * 100))%"
                        : "Starting…",
                    progress: progress,
                    showsTrailingArrow: false,
                    onClick: nil
                )
            case let .extracting(progress):
                BannerShell(
                    title: "Preparing update",
                    subtitle: progress > 0
                        ? "\(Int(progress * 100))%"
                        : nil,
                    progress: progress,
                    showsTrailingArrow: false,
                    onClick: nil
                )
            case .installing:
                BannerShell(
                    title: "Installing…",
                    subtitle: "NoType will restart",
                    progress: nil,
                    indeterminate: true,
                    showsTrailingArrow: false,
                    onClick: nil
                )
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.bottom, DS.Space.s3)
        .animation(DS.Motion.base, value: phaseAnimationKey(updates.phase))
    }

    /// Reduces the rich enum to a Hashable key so SwiftUI's `.animation`
    /// modifier doesn't fire on every download-progress tick (which would
    /// stutter the progress bar).
    private func phaseAnimationKey(_ phase: UpdateController.Phase) -> String {
        switch phase {
        case .idle:        return "idle"
        case .checking:    return "checking"
        case .available:   return "available"
        case .downloading: return "downloading"
        case .extracting:  return "extracting"
        case .installing:  return "installing"
        case .failed:      return "failed"
        }
    }
}

// MARK: - Banner chrome

private struct BannerShell: View {
    let title: String
    let subtitle: String?
    /// `nil` → no progress chrome. `0..<1` → determinate bar at that fill.
    let progress: Double?
    var indeterminate: Bool = false
    /// `true` renders a chevron-right on the trailing edge — the click
    /// affordance for the `.available` phase. Hidden during in-progress
    /// phases (download/extract/install) where clicking is a no-op.
    let showsTrailingArrow: Bool
    /// `nil` makes the banner non-interactive (download/install phases).
    let onClick: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        Button(action: { onClick?() }) {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s3) {
                    AccentPulseDot()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(DS.Font.bodySM(.semibold))
                            .foregroundStyle(DS.Color.textPrimary)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(DS.Font.caption())
                                .foregroundStyle(DS.Color.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if showsTrailingArrow {
                        DSIcon(
                            name: .chevronRight,
                            size: 14,
                            color: isHovered ? DS.Color.textPrimary : DS.Color.textTertiary
                        )
                        .animation(DS.Motion.fast, value: isHovered)
                    }
                }
                if progress != nil || indeterminate {
                    progressTrack
                }
            }
            .padding(.horizontal, DS.Space.s4)
            .padding(.vertical, DS.Space.s3 + 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .disabled(onClick == nil)
        .onHover { isHovered = $0 && onClick != nil }
        .animation(DS.Motion.fast, value: isHovered)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(onClick != nil ? .isButton : [])
    }

    private var background: Color {
        if isHovered { return DS.Color.bgHover }
        return DS.Color.bgSurface
    }

    private var accessibilityLabel: String {
        if let subtitle { return "\(title) — \(subtitle)" }
        return title
    }

    private var progressTrack: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Color.bgInset)
                Capsule()
                    .fill(DS.Color.accent)
                    .frame(width: barWidth(totalWidth: geo.size.width))
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
    }

    private func barWidth(totalWidth: CGFloat) -> CGFloat {
        if indeterminate {
            // Indeterminate is rendered as a solid bar — the calling
            // phase (`installing`) is short-lived enough that animating
            // an indeterminate sweep would be noisier than helpful.
            return totalWidth
        }
        let p = progress ?? 0
        return max(0, min(1, p)) * totalWidth
    }
}

/// Small accent dot with a subtle pulse animation, signalling that a
/// fresh update is waiting. Mirrors the design system's recording-mic
/// pulse but quieter (no halo ring).
private struct AccentPulseDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(DS.Color.accent)
            .frame(width: 8, height: 8)
            .opacity(pulsing ? 0.55 : 1.0)
            .animation(
                .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}
