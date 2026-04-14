import SwiftUI

// MARK: - Mini Sparkline

struct MiniSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let pts = sparkPoints(in: geometry.size)
            if pts.count > 1 {
                Path { path in
                    path.move(to: pts[0])
                    for p in pts.dropFirst() { path.addLine(to: p) }
                }
                .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func sparkPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 0
        let range = max(maxV - minV, 0.0001)
        return values.enumerated().map { i, v in
            let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
            let y = size.height * CGFloat(1 - (v - minV) / range)
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Enums

enum CostGranularity: String, CaseIterable, Identifiable {
    case hourly, daily
    var id: String { rawValue }
}

enum CostMetric: String, CaseIterable, Identifiable {
    case usd, tokens
    var id: String { rawValue }
}

enum DistributionPeriod: String, CaseIterable, Identifiable {
    case today, week, month, overall
    var id: String { rawValue }
}
