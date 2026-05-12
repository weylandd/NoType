import SwiftUI

/// Universal failure surface — network, API quota, paste blocked, key
/// invalid, anything that needs the user's attention. Floats in the
/// top-right next to the recording HUD slot.
///
/// Mirrors the design's `.err-hud`:
/// - 320 pt wide, padding 12.
/// - Tinted icon glyph (red default, amber for warnings) at 26 × 26.
/// - Title (semibold), body description, optional uppercase mono code.
/// - Dismiss button in the top-right.
/// - Optional retry / primary CTA + a secondary text link in the
///   actions row.
struct ErrorHUD: View {
    let payload: ErrorPayload
    var onDismiss:   () -> Void = {}
    var onRetry:     (() -> Void)? = nil
    var onSecondary: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                DSGlyphChip(severity: payload.severity.glyphSeverity, symbol: payload.iconSymbol)

                VStack(alignment: .leading, spacing: 3) {
                    Text(payload.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(payload.description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                    if let code = payload.code {
                        Text(code)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DS.Color.textQuaternary)
                            .textCase(.uppercase)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DSCloseButton(action: onDismiss)
            }

            if payload.retryLabel != nil || payload.secondaryLabel != nil {
                HStack(spacing: 8) {
                    if let label = payload.retryLabel {
                        switch payload.retryKind {
                        case .accent:
                            DSPrimaryButton(label: label) { onRetry?() }
                        case .neutral:
                            DSSecondaryButton(label: label) { onRetry?() }
                        }
                    }
                    if let label = payload.secondaryLabel {
                        DSLinkButton(label: label) { onSecondary?() }
                    }
                }
                .padding(.leading, 36) // align with title (icon 26 + 10 gap)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .dsHudChrome()
    }
}

private extension ErrorPayload.Severity {
    var glyphSeverity: DSGlyphChip.Severity {
        switch self {
        case .danger:  return .danger
        case .warning: return .warning
        case .neutral: return .neutral
        }
    }
}

// MARK: - Payload

struct ErrorPayload: Equatable {
    enum Severity: Equatable { case danger, warning, neutral }
    enum RetryKind: Equatable { case neutral, accent }

    var title: String
    var description: String
    var code: String? = nil
    var severity: Severity = .danger
    var iconSymbol: String = "exclamationmark.triangle.fill"
    var retryLabel: String? = nil
    var retryKind: RetryKind = .neutral
    var secondaryLabel: String? = nil
}
