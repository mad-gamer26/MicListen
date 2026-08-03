import SwiftUI

enum WebTheme {
    static let background = Color(red: 0.031, green: 0.075, blue: 0.071)
    static let panel = Color(red: 0.063, green: 0.129, blue: 0.122)
    static let panelHover = Color(red: 0.078, green: 0.161, blue: 0.145)
    static let line = Color(red: 0.145, green: 0.251, blue: 0.231)
    static let text = Color(red: 0.933, green: 0.973, blue: 0.957)
    static let muted = Color(red: 0.553, green: 0.663, blue: 0.635)
    static let accent = Color(red: 0.345, green: 0.902, blue: 0.663)
    static let accentDeep = Color(red: 0.122, green: 0.722, blue: 0.471)
    static let danger = Color(red: 1.000, green: 0.482, blue: 0.447)
    static let dangerPanel = Color(red: 0.176, green: 0.106, blue: 0.098)
    static let dangerLine = Color(red: 0.439, green: 0.286, blue: 0.255)
}

struct WebBackground: View {
    var body: some View {
        WebTheme.background
            .ignoresSafeArea()
    }
}

struct WebBrandMark: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            ForEach(Array(barHeights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(WebTheme.accent)
                    .frame(width: compact ? 3 : 4, height: compact ? height * 0.78 : height)
            }
        }
        .frame(width: compact ? 52 : 66, height: compact ? 52 : 66)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.094, green: 0.212, blue: 0.184),
                    Color(red: 0.051, green: 0.118, blue: 0.106)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: compact ? 15 : 19, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 15 : 19, style: .continuous)
                .stroke(Color(red: 0.169, green: 0.333, blue: 0.294), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 14)
        .accessibilityHidden(true)
    }

    private var barHeights: [CGFloat] {
        [14, 27, 39, 27, 14]
    }
}

struct WebHero: View {
    let title: String
    let subtitle: String
    let trailing: AnyView?

    init<Content: View>(title: String, subtitle: String, @ViewBuilder trailing: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = AnyView(trailing())
    }

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 22) {
                WebBrandMark()

                VStack(alignment: .leading, spacing: 11) {
                    Text(title)
                        .font(.system(size: 44, weight: .bold, design: .default))
                        .foregroundStyle(WebTheme.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.74)
                    Text(subtitle)
                        .font(.system(size: 16))
                        .foregroundStyle(WebTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if let trailing {
                    trailing
                }
            }
            .padding(.bottom, 36)

            Rectangle()
                .fill(WebTheme.line)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct WebIconButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 43, height: 43)
                .accessibilityHidden(true)
        }
        .foregroundStyle(WebTheme.muted)
        .background(WebTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(WebTheme.line, lineWidth: 1)
        )
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct WebActionButton: View {
    let title: String
    let systemImage: String
    let role: ButtonRole?
    let action: () -> Void

    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(height: 43)
        }
        .foregroundStyle(role == .destructive ? Color(red: 1, green: 0.753, blue: 0.718) : WebTheme.text)
        .padding(.horizontal, 14)
        .background(role == .destructive ? Color(red: 0.161, green: 0.098, blue: 0.090) : WebTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(role == .destructive ? Color(red: 0.439, green: 0.275, blue: 0.247) : WebTheme.line, lineWidth: 1)
        )
        .buttonStyle(.plain)
    }
}

struct WebNotice: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 15))
            .foregroundStyle(Color(red: 1, green: 0.761, blue: 0.725))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(WebTheme.dangerPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(WebTheme.dangerLine, lineWidth: 1)
            )
    }
}

struct WebPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            WebBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .frame(maxWidth: 1080, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 34)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct StatusBadge: View {
    let title: String
    let systemImage: String?
    let color: Color

    init(_ title: String, systemImage: String? = nil, color: Color = .secondary) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

struct ProblemBlock: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(message)
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
    }
}

struct HeaderMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}
