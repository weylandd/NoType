import AppKit
import SwiftUI

/// Final row inside the About card. Opens the NoType GitHub
/// repository in the user's default browser when clicked.
struct GitHubRow: View {
    private static let url = URL(string: "https://github.com/weylandd/NoType")!

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: DS.Space.s3 + 2) {
                iconWell
                VStack(alignment: .leading, spacing: 1) {
                    Text("View source on GitHub")
                        .font(DS.Font.body(.medium))
                        .foregroundStyle(DS.Color.textPrimary)
                    Text("github.com/weylandd/NoType · MIT License")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.Color.textTertiary)
                }
                Spacer(minLength: 0)
                DSIcon(name: .arrowUpRight, size: 12, color: DS.Color.textTertiary)
            }
            .padding(.horizontal, DS.Space.s5 - 2)
            .padding(.vertical, DS.Space.s4 + 2)
            .background(
                hovering ? DS.Color.bgHover : .clear
            )
            .overlay(
                DS.Color.borderSubtle.frame(height: DS.Border.hairline),
                alignment: .top
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("View source on GitHub")
    }

    private var iconWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(DS.Color.bgInset)
                .frame(width: 30, height: 30)
            DSIcon(name: .code, size: 14, color: DS.Color.textPrimary)
        }
    }

    private func open() {
        NSWorkspace.shared.open(Self.url)
    }
}
