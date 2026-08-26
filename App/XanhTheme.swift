import SwiftUI

extension Color {
    static let xanhBackground = Color(red: 0.018, green: 0.055, blue: 0.035)
    static let xanhPanel = Color(red: 0.035, green: 0.105, blue: 0.066)
    static let xanhRaised = Color(red: 0.059, green: 0.157, blue: 0.098)
    static let xanhGreen = Color(red: 0.30, green: 0.83, blue: 0.42)
    static let xanhLeaf = Color(red: 0.67, green: 0.95, blue: 0.58)
    static let xanhCream = Color(red: 0.91, green: 0.97, blue: 0.92)
    static let xanhMuted = Color(red: 0.61, green: 0.74, blue: 0.64)
    static let xanhBorder = Color(red: 0.14, green: 0.32, blue: 0.20)
}

struct XanhPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.xanhPanel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.xanhBorder, lineWidth: 1)
            }
    }
}

extension View {
    func xanhPanel() -> some View {
        modifier(XanhPanelModifier())
    }
}

struct XanhSectionLabel: View {
    let title: String
    let index: String

    var body: some View {
        HStack(spacing: 10) {
            Text(index)
                .foregroundStyle(Color.xanhLeaf)
            Rectangle()
                .fill(Color.xanhLeaf)
                .frame(width: 18, height: 2)
            Text(title.uppercased())
                .foregroundStyle(Color.xanhMuted)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer()
        }
        .font(.caption.monospaced().weight(.bold))
        .accessibilityElement(children: .combine)
    }
}

struct XanhBrandMark: View {
    var size: CGFloat = 44

    var body: some View {
        Image("XanhMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct XanhSignalField: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: -24, y: proxy.size.height * 0.92))
                path.addCurve(
                    to: CGPoint(x: proxy.size.width + 30, y: proxy.size.height * 0.08),
                    control1: CGPoint(x: proxy.size.width * 0.30, y: proxy.size.height * 0.82),
                    control2: CGPoint(x: proxy.size.width * 0.72, y: proxy.size.height * 0.24)
                )
            }
            .stroke(
                Color.xanhLeaf.opacity(0.16),
                style: StrokeStyle(lineWidth: 1, dash: [7, 11])
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
