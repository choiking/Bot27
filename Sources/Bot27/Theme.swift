import SwiftUI

enum Theme {
    static let sidebar = Color(white: 0.94)
    static let bg = Color(white: 0.972)
    static let card = Color.white
    static let bubble = Color(white: 0.915)
    static let userBubble = Color(white: 0.1)
    static let chip = Color(white: 0.93)
    static let codeBg = Color.white.opacity(0.75)
    static let selected = Color.black.opacity(0.07)
    static let hover = Color.black.opacity(0.04)
    static let border = Color.black.opacity(0.08)
    static let text = Color(white: 0.1)
    static let secondary = Color(white: 0.47)
    static let unread = Color(red: 0.22, green: 0.47, blue: 0.96)
    static let warning = Color(red: 0.83, green: 0.52, blue: 0.08)

    static let avatarColors: [Color] = [
        Color(white: 0.06),
        Color(red: 0.94, green: 0.55, blue: 0.16),
        Color(white: 0.56),
        Color(red: 0.24, green: 0.72, blue: 0.42),
        Color(red: 0.26, green: 0.5, blue: 0.96),
        Color(red: 0.58, green: 0.42, blue: 0.92),
        Color(red: 0.95, green: 0.4, blue: 0.58),
    ]
    static let avatarShapes = 4
}

extension View {
    func cardStyle(radius: CGFloat = 18) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

/// Little creature avatars: a shape in a color, with eyes.
struct BotAvatar: View {
    var shape: Int
    var color: Int
    var size: CGFloat = 36

    private var fill: Color { Theme.avatarColors[color % Theme.avatarColors.count] }

    var body: some View {
        ZStack {
            switch shape % Theme.avatarShapes {
            case 0:
                Circle().fill(fill)
                Circle().fill(.white).frame(width: size * 0.34)
                    .overlay(Circle().fill(fill).frame(width: size * 0.13).offset(x: size * 0.03, y: -size * 0.02))
                    .offset(x: size * 0.15, y: -size * 0.12)
            case 1:
                Hexagon().fill(fill)
                    .overlay(Hexagon().stroke(fill, style: StrokeStyle(lineWidth: size * 0.14, lineJoin: .round)))
                    .padding(size * 0.06)
                HStack(spacing: size * 0.16) {
                    Circle().fill(.white).frame(width: size * 0.12)
                    Circle().fill(.white).frame(width: size * 0.12)
                }
                .offset(x: size * 0.04, y: -size * 0.04)
            case 2:
                UnevenRoundedRectangle(topLeadingRadius: size * 0.5, bottomLeadingRadius: size * 0.16,
                                       bottomTrailingRadius: size * 0.42, topTrailingRadius: size * 0.08)
                    .fill(fill)
                    .rotationEffect(.degrees(-12))
                    .padding(size * 0.06)
                Circle().fill(.white).frame(width: size * 0.13).offset(x: size * 0.12, y: -size * 0.05)
            default:
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(fill)
                    .rotationEffect(.degrees(-14))
                    .padding(size * 0.1)
                HStack(spacing: size * 0.12) {
                    Capsule().fill(.white).frame(width: size * 0.08, height: size * 0.2)
                    Capsule().fill(.white).frame(width: size * 0.08, height: size * 0.2)
                }
                .rotationEffect(.degrees(-14))
                .offset(y: -size * 0.03)
            }
        }
        .frame(width: size, height: size)
    }
}

struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<6 {
            let a = (Double(i) * 60 - 90 + 15) * .pi / 180
            let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

/// White circular button with a soft shadow (sidebar toolbar).
struct CircleButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 34, height: 34)
                .background(Circle().fill(hover ? Color(white: 0.98) : .white))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover ? Theme.text : Theme.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
