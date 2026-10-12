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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        theme: CompanionTheme,
        listening: Bool = false,
        level: Float = 0,
        size: CGFloat = 112,
        watchInkMask: Bool = false
    ) {
        self.theme = theme
        self.listening = listening
        self.level = level
        self.size = size
        self.watchInkMask = watchInkMask
    }

    private var spriteColumn: Int {
        listening ? 1 : 0
    }

    private var animatedScale: CGFloat {
        guard listening, !reduceMotion else { return 1 }
        return 1 + CGFloat(max(0, min(1, level))) * 0.035
    }

    var body: some View {
        GeometryReader { geometry in
            let tile = geometry.size.width
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
            .offset(x: -CGFloat(spriteColumn) * tile, y: -CGFloat(theme.spriteRow) * tile)
        }
        .frame(width: size, height: size)
        .clipped()
        .scaleEffect(animatedScale)
        .animation(.easeOut(duration: 0.18), value: level)
        .accessibilityHidden(true)
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
