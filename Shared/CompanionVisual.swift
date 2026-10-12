import SwiftUI

enum CompanionTheme: String, CaseIterable, Identifiable {
    case ink, star, sprout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ink: return "呼吸墨点"
        case .star: return "暖星"
        case .sprout: return "纸芽"
        }
    }

    var description: String {
        switch self {
        case .ink: return "两笔，就有回应"
        case .star: return "温暖的手绘星"
        case .sprout: return "草绿的折纸书签"
        }
    }

    var color: Color {
        switch self {
        case .ink: return Color(hex: 0x55564E)
        case .star: return Color(hex: 0xAE6047)
        case .sprout: return Color(hex: 0x577D3E)
        }
    }

    var softColor: Color {
        switch self {
        case .ink: return Color(hex: 0xE8E7DE)
        case .star: return Color(hex: 0xEFE0D5)
        case .sprout: return Color(hex: 0xE5EDDB)
        }
    }

    var background: Color {
        self == .sprout ? Color(hex: 0xF7F7EF) : Color(hex: 0xF8F5EF)
    }

    fileprivate var spriteRow: Int {
        switch self {
        case .star: return 0
        case .ink: return 1
        case .sprout: return 2
        }
    }
}

enum Palette {
    static let ink = Color(hex: 0x262520)
    static let muted = Color(hex: 0x82817C)
    static let line = Color(hex: 0xDED9D1)
}

struct CompanionVisual: View {
    let theme: CompanionTheme
    var listening = false
    var level: Float = 0
    var size: CGFloat = 112
    var watchInkMask = false
    var centered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        theme: CompanionTheme,
        listening: Bool = false,
        level: Float = 0,
        size: CGFloat = 112,
        watchInkMask: Bool = false,
        centered: Bool = false
    ) {
        self.theme = theme
        self.listening = listening
        self.level = level
        self.size = size
        self.watchInkMask = watchInkMask
        self.centered = centered
    }

    private var animatedScale: CGFloat {
        guard listening, !reduceMotion else { return 1 }
        return 1 + CGFloat(max(0, min(1, level))) * 0.035
    }

    // Sprite cells have different transparent margins; align their visible content on Watch.
    private func contentOffset(listening: Bool) -> CGSize {
        guard centered else { return .zero }
        switch theme {
        case .star: return CGSize(width: listening ? -0.052 : -0.041, height: -0.119)
        case .ink: return CGSize(width: listening ? -0.019 : -0.054, height: listening ? 0.043 : 0.023)
        case .sprout: return CGSize(width: listening ? -0.072 : -0.043, height: listening ? 0.145 : 0.124)
        }
    }

    var body: some View {
        ZStack {
            spriteCell(listening: false).opacity(listening ? 0 : 1)
            spriteCell(listening: true).opacity(listening ? 1 : 0)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: listening)
        .frame(width: size, height: size)
        .scaleEffect(animatedScale)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: level)
        .accessibilityHidden(true)
    }

    private func spriteCell(listening: Bool) -> some View {
        GeometryReader { geometry in
            let tile = geometry.size.width
            let offset = contentOffset(listening: listening)
            Group {
                if watchInkMask && theme == .ink {
                    Image("CompanionSprite")
                        .renderingMode(.template)
                        .interpolation(.high)
                        .resizable()
                        .foregroundStyle(.white)
                } else {
                    Image("CompanionSprite").interpolation(.high).resizable()
                }
            }
            .frame(width: tile * 4, height: tile * 3, alignment: .topLeading)
            .offset(x: (-CGFloat(listening ? 1 : 0) + offset.width) * tile,
                    y: (-CGFloat(theme.spriteRow) + offset.height) * tile)
        }
        .frame(width: size, height: size)
        .clipped()
        .transaction { $0.animation = nil }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

func durationText(_ duration: Double) -> String {
    let seconds = Int(max(0, duration))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
