import SwiftUI

extension CostTrackingView {

    var modelTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Model Details", "模型详情"))
                .font(.headline.weight(.bold))

            if models.isEmpty {
                Text(L("No model data", "暂无模型数据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text(L("Model", "模型")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L("Cost", "费用")).frame(width: 80, alignment: .trailing)
                        Text("Tokens").frame(width: 80, alignment: .trailing)
                        Text(L("Share", "占比")).frame(width: 60, alignment: .trailing)
                        Text(L("Trend", "趋势")).frame(width: 70, alignment: .center)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        modelRow(model, index: index)
                        if expandedModel == model.model {
                            modelDetailRow(model, index: index)
                        }
                        if index < models.count - 1 {
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

    func modelRow(_ model: ModelCostBreakdown, index: Int) -> some View {
        let color = modelColor(index)
        let sparkValues = modelSparklineValues(model.model)
        let isExpanded = expandedModel == model.model
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Circle().fill(color).frame(width: 8, height: 8)
                Text(shortModelName(model.model))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatCurrency(model.estimatedCostUsd))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 80, alignment: .trailing)

            Text(formatCompactNumber(Double(model.totalTokens)))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(String(format: "%.1f%%", model.percentage))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 60, alignment: .trailing)

            MiniSparkline(values: sparkValues, color: color)
                .frame(width: 56, height: 20)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedModel = expandedModel == model.model ? nil : model.model
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
        let color = modelColor(index)
        return HStack(spacing: 16) {
            Spacer().frame(width: 28)
            tokenBreakdownPill(label: L("Input", "输入"), tokens: model.inputTokens, color: .blue)
            tokenBreakdownPill(label: L("Output", "输出"), tokens: model.outputTokens, color: .green)
            tokenBreakdownPill(label: L("Cache Read", "缓存读取"), tokens: model.cacheReadTokens, color: .orange)
            tokenBreakdownPill(label: L("Cache Write", "缓存写入"), tokens: model.cacheCreateTokens, color: .purple)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
