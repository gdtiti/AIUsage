import Foundation

public struct CanonicalOpenAIUpstreamStreamMapper {
    private var didEmitMessageStart = false
    private var nextContentIndex = 0
    private var textContentIndex: Int?
    private var reasoningContentIndex: Int?
    private var toolContentIndices: [Int: Int] = [:]
    private var pendingToolArgumentDeltas: [Int: [String]] = [:]
    private var openContentIndices = Set<Int>()

    public init() {}

    public mutating func map(
        _ event: OpenAIUpstreamStreamEvent,
        role: CanonicalRole = .assistant
    ) -> [CanonicalStreamEvent] {
        var mappedEvents: [CanonicalStreamEvent] = []
        emitMessageStartIfNeeded(into: &mappedEvents, role: role)

        switch event {
        case .textDelta(let text):
            closeReasoningContentIfNeeded(into: &mappedEvents)
            let index = ensureTextContentPartStarted(into: &mappedEvents)
            mappedEvents.append(.contentPartDelta(CanonicalStreamContentPartDelta(
                index: index,
                kind: .text,
                textDelta: text
            )))

        case .reasoningSummaryDelta(let text):
            closeTextContentIfNeeded(into: &mappedEvents)
            let index = ensureReasoningContentPartStarted(into: &mappedEvents)
            mappedEvents.append(.contentPartDelta(CanonicalStreamContentPartDelta(
                index: index,
                kind: .reasoning,
                textDelta: text
            )))

        case .toolCallStarted(let upstreamIndex, let id, let name):
            closeReasoningContentIfNeeded(into: &mappedEvents)
            closeTextContentIfNeeded(into: &mappedEvents)
            let contentIndex = ensureToolContentPartStarted(
                upstreamIndex: upstreamIndex,
                toolCallID: id,
                toolName: name,
                into: &mappedEvents
            )
            if !openContentIndices.contains(contentIndex) {
                openContentIndices.insert(contentIndex)
            }
            flushPendingToolArgumentDeltas(
                for: upstreamIndex,
                contentIndex: contentIndex,
                into: &mappedEvents
            )

        case .toolCallArgumentsDelta(let upstreamIndex, let argumentsDelta):
            if let contentIndex = toolContentIndices[upstreamIndex] {
                mappedEvents.append(.contentPartDelta(CanonicalStreamContentPartDelta(
                    index: contentIndex,
                    kind: .toolCall,
                    jsonDelta: argumentsDelta
                )))
            } else if !argumentsDelta.isEmpty {
                pendingToolArgumentDeltas[upstreamIndex, default: []].append(argumentsDelta)
            }

        case .completed(let finishReason, let usage):
            closeReasoningContentIfNeeded(into: &mappedEvents)
            closeTextContentIfNeeded(into: &mappedEvents)
            for upstreamIndex in pendingToolArgumentDeltas.keys.sorted() {
                let contentIndex = ensureToolContentPartStarted(
                    upstreamIndex: upstreamIndex,
                    toolCallID: nil,
                    toolName: nil,
                    into: &mappedEvents
                )
                flushPendingToolArgumentDeltas(
                    for: upstreamIndex,
                    contentIndex: contentIndex,
                    into: &mappedEvents
                )
            }
            for index in openContentIndices.sorted() {
                mappedEvents.append(.contentPartStopped(CanonicalStreamContentPartStopped(index: index)))
            }
            openContentIndices.removeAll()
            mappedEvents.append(.messageDelta(CanonicalStreamMessageDelta(
                stop: finishReason.map { CanonicalStop(reason: canonicalStreamStopReasonFromOpenAI($0)) },
                usage: usage.map { u in
                    CanonicalUsage(
                        inputTokens: u.effectiveInputTokens,
                        outputTokens: u.completionTokens,
                        totalTokens: u.totalTokens,
                        cacheCreationInputTokens: nil,
                        cacheReadInputTokens: u.effectiveCachedTokens
                    )
                }
            )))
            mappedEvents.append(.messageStopped)
        }

        return mappedEvents
    }

    private mutating func emitMessageStartIfNeeded(
        into events: inout [CanonicalStreamEvent],
        role: CanonicalRole
    ) {
        guard !didEmitMessageStart else { return }
        didEmitMessageStart = true
        events.append(.messageStarted(CanonicalStreamMessageStarted(role: role)))
    }

    private mutating func ensureTextContentPartStarted(
        into events: inout [CanonicalStreamEvent]
    ) -> Int {
        if let textContentIndex {
            return textContentIndex
        }

        let index = nextContentIndex
        nextContentIndex += 1
        textContentIndex = index
        openContentIndices.insert(index)
        events.append(.contentPartStarted(CanonicalStreamContentPartStarted(index: index, kind: .text)))
        return index
    }

    private mutating func ensureReasoningContentPartStarted(
        into events: inout [CanonicalStreamEvent]
    ) -> Int {
        if let reasoningContentIndex {
            return reasoningContentIndex
        }

        let index = nextContentIndex
        nextContentIndex += 1
        reasoningContentIndex = index
        openContentIndices.insert(index)
        events.append(.contentPartStarted(CanonicalStreamContentPartStarted(index: index, kind: .reasoning)))
        return index
    }

    private mutating func ensureToolContentPartStarted(
        upstreamIndex: Int,
        toolCallID: String?,
        toolName: String?,
        into events: inout [CanonicalStreamEvent]
    ) -> Int {
        if let existingIndex = toolContentIndices[upstreamIndex] {
            return existingIndex
        }

        let index = nextContentIndex
        nextContentIndex += 1
        toolContentIndices[upstreamIndex] = index
        openContentIndices.insert(index)
        events.append(.contentPartStarted(CanonicalStreamContentPartStarted(
            index: index,
            kind: .toolCall,
            toolCallID: toolCallID,
            toolName: toolName
        )))
        return index
    }

    private mutating func closeTextContentIfNeeded(
        into events: inout [CanonicalStreamEvent]
    ) {
        guard let index = textContentIndex, openContentIndices.contains(index) else { return }
        openContentIndices.remove(index)
        textContentIndex = nil
        events.append(.contentPartStopped(CanonicalStreamContentPartStopped(index: index)))
    }

    private mutating func closeReasoningContentIfNeeded(
        into events: inout [CanonicalStreamEvent]
    ) {
        guard let index = reasoningContentIndex, openContentIndices.contains(index) else { return }
        openContentIndices.remove(index)
        reasoningContentIndex = nil
        events.append(.contentPartStopped(CanonicalStreamContentPartStopped(index: index)))
    }

    private mutating func flushPendingToolArgumentDeltas(
        for upstreamIndex: Int,
        contentIndex: Int,
        into events: inout [CanonicalStreamEvent]
    ) {
        guard let deltas = pendingToolArgumentDeltas.removeValue(forKey: upstreamIndex) else {
            return
        }

        for delta in deltas where !delta.isEmpty {
            events.append(.contentPartDelta(CanonicalStreamContentPartDelta(
                index: contentIndex,
                kind: .toolCall,
                jsonDelta: delta
            )))
        }
    }
}

public struct CanonicalClaudeStreamMapper {
    public init() {}

    public func map(_ event: ClaudeStreamEvent) -> [CanonicalStreamEvent] {
        switch event {
        case .messageStart(let messageStart):
            return [.messageStarted(CanonicalStreamMessageStarted(
                role: canonicalStreamRole(from: messageStart.message.role),
                messageID: messageStart.message.id,
                model: messageStart.message.model
            ))]

        case .contentBlockStart(let blockStart):
            return [.contentPartStarted(CanonicalStreamContentPartStarted(
                index: blockStart.index,
                kind: canonicalStreamPartKind(from: blockStart.contentBlock),
                toolCallID: toolCallID(from: blockStart.contentBlock),
                toolName: toolName(from: blockStart.contentBlock)
            ))]

        case .contentBlockDelta(let deltaEvent):
            return mapClaudeContentDelta(deltaEvent)

        case .contentBlockStop(let blockStop):
            return [.contentPartStopped(CanonicalStreamContentPartStopped(index: blockStop.index))]

        case .messageDelta(let messageDelta):
            return [.messageDelta(CanonicalStreamMessageDelta(
                stop: messageDelta.delta.stopReason.map {
                    CanonicalStop(
                        reason: canonicalStreamStopReasonFromClaude($0),
                        sequence: messageDelta.delta.stopSequence
                    )
                },
                usage: CanonicalUsage(outputTokens: messageDelta.usage.outputTokens)
            ))]

        case .messageStop:
            return [.messageStopped]

        case .ping:
            return []
        }
    }
}

private func mapClaudeContentDelta(_ event: ClaudeContentBlockDeltaEvent) -> [CanonicalStreamEvent] {
    switch event.delta {
    case .text(let text):
        return [.contentPartDelta(CanonicalStreamContentPartDelta(
            index: event.index,
            kind: .text,
            textDelta: text.text
        ))]

    case .inputJson(let inputJSON):
        return [.contentPartDelta(CanonicalStreamContentPartDelta(
            index: event.index,
            kind: .toolCall,
            jsonDelta: inputJSON.partialJson
        ))]

    case .thinking(let thinking):
        return [.contentPartDelta(CanonicalStreamContentPartDelta(
            index: event.index,
            kind: .reasoning,
            textDelta: thinking.thinking
        ))]

    case .signature(let signature):
        return [.contentPartDelta(CanonicalStreamContentPartDelta(
            index: event.index,
            kind: .reasoning,
            rawExtensions: [
                CanonicalVendorExtension(
                    vendor: "claude",
                    key: "signature_delta",
                    value: AnyCodable(signature.signature)
                )
            ]
        ))]

    case .citations, .unknown:
        return []
    }
}

private func canonicalStreamRole(from raw: String) -> CanonicalRole {
    switch raw {
    case "system":
        return .system
    case "user":
        return .user
    case "assistant":
        return .assistant
    case "tool":
        return .tool
    case "developer":
        return .developer
    default:
        return .unknown(raw)
    }
}

private func canonicalStreamPartKind(from block: ClaudeContentBlock) -> CanonicalStreamPartKind {
    switch block {
    case .text:
        return .text
    case .toolUse:
        return .toolCall
    case .thinking, .redactedThinking:
        return .reasoning
    case .image:
        return .unknown("image")
    case .document:
        return .unknown("document")
    case .toolResult:
        return .unknown("tool_result")
    case .unknown(let block):
        return .unknown(block.type)
    }
}

private func toolCallID(from block: ClaudeContentBlock) -> String? {
    guard case .toolUse(let toolUse) = block else { return nil }
    return toolUse.id
}

private func toolName(from block: ClaudeContentBlock) -> String? {
    guard case .toolUse(let toolUse) = block else { return nil }
    return toolUse.name
}

private func canonicalStreamStopReasonFromOpenAI(_ raw: String) -> CanonicalStopReason {
    switch raw {
    case "stop", "end_turn":
        return .endTurn
    case "tool_calls":
        return .toolUse
    case "length":
        return .maxTokens
    case "pause_turn":
        return .pauseTurn
    case "refusal", "content_filter":
        return .refusal
    case "model_context_window_exceeded":
        return .modelContextWindowExceeded
    default:
        return .unknown(raw)
    }
}

private func canonicalStreamStopReasonFromClaude(_ raw: String) -> CanonicalStopReason {
    switch raw {
    case "end_turn", "stop":
        return .endTurn
    case "tool_use":
        return .toolUse
    case "max_tokens":
        return .maxTokens
    case "pause_turn":
        return .pauseTurn
    case "refusal":
        return .refusal
    case "model_context_window_exceeded":
        return .modelContextWindowExceeded
    default:
        return .unknown(raw)
    }
}
