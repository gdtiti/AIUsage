import SwiftUI

extension CostTrackingView {

    private func tableColumnWidth(_ column: CostTrackingTableColumn, layout: CostTrackingInsightsLayout) -> CGFloat {
        switch (layout, column) {
        case (.split, .cost): return 88
        case (.split, .tokens): return 88
        case (.split, .share): return 62
        case (.split, .trend): return 72
        case (.stacked, .cost): return 96
        case (.stacked, .tokens): return 96
        case (.stacked, .share): return 68
        case (.stacked, .trend): return 78
        }
    }

    func modelTable(layout: CostTrackingInsightsLayout) -> some View {
        let costWidth = tableColumnWidth(.cost, layout: layout)
        let tokensWidth = tableColumnWidth(.tokens, layout: layout)
        let shareWidth = tableColumnWidth(.share, layout: layout)
        let trendWidth = tableColumnWidth(.trend, layout: layout)

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Model Details", "模型详情"))
                .font(.headline.weight(.bold))

            if rankedDistributionModels.isEmpty {
                Text(L("No model data", "暂无模型数据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text(L("Model", "模型")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L("Cost", "费用")).frame(width: costWidth, alignment: .trailing)
                        Text("Tokens").frame(width: tokensWidth, alignment: .trailing)
                        Text(L("Share", "占比")).frame(width: shareWidth, alignment: .trailing)
                        Text(L("Trend", "趋势")).frame(width: trendWidth, alignment: .center)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    ForEach(Array(rankedDistributionModels.enumerated()), id: \.element.id) { index, model in
                        modelRow(
                            model,
                            index: index,
                            costWidth: costWidth,
                            tokensWidth: tokensWidth,
                            shareWidth: shareWidth,
                            trendWidth: trendWidth
                        )
                        if expandedModels.contains(model.model) {
                            modelDetailRow(model, index: index)
                        }
                        if index < rankedDistributionModels.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    func modelRow(
        _ model: ModelCostBreakdown,
        index: Int,
        costWidth: CGFloat,
        tokensWidth: CGFloat,
        shareWidth: CGFloat,
        trendWidth: CGFloat
    ) -> some View {
        let color = modelColor(for: model.model)
        let sparkValues = modelSparklineValues(model.model)
        let isExpanded = expandedModels.contains(model.model)
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Circle().fill(color).frame(width: 8, height: 8)
                Text(model.model)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatCurrency(model.estimatedCostUsd))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: costWidth, alignment: .trailing)

            Text(formatCompactNumber(Double(model.totalTokens)))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: tokensWidth, alignment: .trailing)

            Text(String(format: "%.1f%%", distributionShare(for: model)))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .frame(width: shareWidth, alignment: .trailing)

            MiniSparkline(values: sparkValues, color: color)
                .frame(width: max(56, trendWidth - 8), height: 20)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if expandedModels.contains(model.model) {
                    expandedModels.remove(model.model)
                } else {
                    expandedModels.insert(model.model)
                }
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            toggleModelSelection(model.model)
        })
        .background(
            selectedModels.contains(model.model)
                ? RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08))
                : nil
        )
    }

    func modelDetailRow(_ model: ModelCostBreakdown, index: Int) -> some View {
        let color = modelColor(for: model.model)
        let detailItems: [(String, Int, Color)] = [
            (L("Input", "输入"), model.inputTokens, .blue),
            (L("Output", "输出"), model.outputTokens, .green),
            (L("Cache Read", "缓存读取"), model.cacheReadTokens, .orange),
            (L("Cache Write", "缓存写入"), model.cacheCreateTokens, .purple)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(detailItems, id: \.0) { item in
                    tokenBreakdownPill(label: item.0, tokens: item.1, color: item.2)
                }
            }

            HStack {
                Spacer()
                Button {
                    toggleModelSelection(model.model)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selectedModels.contains(model.model) ? "checkmark.circle.fill" : "circle")
                        Text(L("Compare", "对比"))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selectedModels.contains(model.model) ? color : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.04))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    func tokenBreakdownPill(label: String, tokens: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(formatCompactNumber(Double(tokens)))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.08)))
    }
}

private enum CostTrackingTableColumn {
    case cost
    case tokens
    case share
    case trend
}
