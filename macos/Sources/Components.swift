import SwiftUI

/// The rounded gradient tile beside a row or a sidebar item.
struct IconTile: View {
    let symbol: String
    let hue: Int
    var size: CGFloat = 26

    var body: some View {
        let color = Chrome.tileHues[hue % Chrome.tileHues.count]
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

/// Equal cells in one card with a highlight that slides between them.
struct TileSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String, symbol: String)]
    let selection: Value?
    var vertical = false
    let onSelect: (Value) -> Void

    @Namespace private var highlight
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 && selection != option.value && selection != options[index - 1].value {
                    Rectangle().fill(Chrome.overlay(0.1)).frame(width: 1, height: 16)
                } else if index > 0 {
                    Color.clear.frame(width: 1, height: 16)
                }
                cell(option)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Chrome.overlay(0.05)))
        .animation(Chrome.panelSlide, value: selection)
    }

    @ViewBuilder
    private func cell(_ option: (value: Value, title: String, symbol: String)) -> some View {
        let isSelected = option.value == selection
        Button { onSelect(option.value) } label: {
            Group {
                if vertical {
                    VStack(spacing: 5) {
                        Image(systemName: option.symbol).font(.system(size: 15, weight: .medium))
                        Text(verbatim: option.title).font(.system(size: 11, weight: .medium))
                    }
                    .frame(height: 50)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: option.symbol).font(.system(size: 11, weight: .medium))
                        Text(verbatim: option.title).font(.system(size: 12, weight: .medium))
                    }
                    .frame(height: 30)
                }
            }
            .lineLimit(1)
            .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 1 : 0.72))
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Chrome.overlay(0.13))
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                } else if hovered == option.value {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.overlay(0.05))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { hovered = h ? option.value : nil } }
    }
}
