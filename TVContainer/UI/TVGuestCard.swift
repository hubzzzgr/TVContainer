import SwiftUI

struct TVGuestCard: View {
    let app: TVGuest

    private var artworkWidth: CGFloat {
        min(400, max(220, 200 * app.artworkAspectRatio))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let icon = app.icon {
                    Image(uiImage: icon).resizable().interpolation(.high).scaledToFit()
                } else {
                    ZStack {
                        Color.blue.gradient
                        Image(systemName: "app.dashed").font(.system(size: 66)).foregroundStyle(.white)
                    }
                }
            }
            .frame(width: artworkWidth, height: artworkWidth / app.artworkAspectRatio)
            .clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(app.name).font(.headline).lineLimit(1)
                Text(app.version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: artworkWidth)
        .background(.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

// Different icon shapes get different card widths. Wrap complete cards into
// rows instead of stretching every card to an adaptive grid column's width.
struct TVAppFlowLayout: Layout {
    var spacing: CGFloat = 40
    var rowSpacing: CGFloat = 44

    private func positions(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (points, CGSize(width: width, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1200
        return positions(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = positions(width: bounds.width, subviews: subviews)
        for (index, view) in subviews.enumerated() {
            let point = result.points[index]
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                       anchor: .topLeading, proposal: ProposedViewSize(view.sizeThatFits(.unspecified)))
        }
    }
}
