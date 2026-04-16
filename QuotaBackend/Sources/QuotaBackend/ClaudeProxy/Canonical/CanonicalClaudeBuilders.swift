import Foundation

public struct CanonicalClaudeResponseBuilder {
    public init() {}

    public func buildMessageResponse(
        from response: CanonicalResponse,
        originalModel: String? = nil
    ) throws -> CanonicalBuildResult<ClaudeMessageResponse> {
        var lossyNotes: [CanonicalLossyNote] = []
        var content: [ClaudeContentBlock] = []

        for (itemIndex, item) in response.items.enumerated() {
            switch item {
            case .message(let message):
                guard case .assistant = message.role else { continue }
                content.append(contentsOf: makeClaudeContentBlocks(
                    from: message.parts,
                    itemIndex: itemIndex,
                    lossyNotes: &lossyNotes
                ))

            case .toolCall(let toolCall):
                content.append(.toolUse(ClaudeToolUseBlock(
                    id: toolCall.id,
                    name: toolCall.name,
                    input: try parseCanonicalToolInput(toolCall.inputJSON)
                )))

            case .reasoning(let reasoning):
                if reasoning.redacted == true {
                    let redactedData = reasoning.rawExtensions.first(where: {
                        $0.vendor == "claude" && $0.key == "redacted_data"
                    })?.value.value as? String ?? reasoning.encryptedContent ?? ""
                    content.append(.redactedThinking(ClaudeRedactedThinkingBlock(data: redactedData)))
                } else if let text = reasoning.fullText ?? reasoning.summaryText {
                    content.append(.thinking(ClaudeThinkingBlock(
                        thinking: text,
                        signature: reasoning.signature
                    )))
                }

            case .toolResult:
                appendClaudeLossyNote(
                    to: &lossyNotes,
                    code: "claude_tool_result_skipped_in_response",
                    message: "Canonical tool_result items are not emitted in Claude assistant responses and were skipped.",
                    itemIndex: itemIndex,
                    path: "items[\(itemIndex)]"
                )

            case .compaction:
                appendClaudeLossyNote(
                    to: &lossyNotes,
                    code: "claude_compaction_skipped_in_response",
                    message: "Canonical compaction items are not representable in Claude assistant responses and were skipped.",
                    itemIndex: itemIndex,
                    path: "items[\(itemIndex)]"
                )

            case .hostedToolEvent:
                appendClaudeLossyNote(
                    to: &lossyNotes,
                    code: "claude_hosted_tool_event_skipped_in_response",
                    message: "Canonical hosted tool events are not representable in Claude assistant responses and were skipped.",
                    itemIndex: itemIndex,
                    path: "items[\(itemIndex)]"
                )
            }
        }

        if content.isEmpty {
            content = [.text(ClaudeTextBlock(text: ""))]
        }

        let payload = ClaudeMessageResponse(
            id: response.id ?? UUID().uuidString,
            type: "message",
            role: "assistant",
            content: content,
            model: originalModel ?? response.model ?? "claude",
            stopReason: canonicalClaudeStopReason(response.stop.reason),
            stopSequence: response.stop.sequence,
            usage: ClaudeUsage(
                inputTokens: response.usage?.inputTokens ?? 0,
                outputTokens: response.usage?.outputTokens ?? 0,
                cacheCreationInputTokens: response.usage?.cacheCreationInputTokens,
                cacheReadInputTokens: response.usage?.cacheReadInputTokens
            )
        )
        return CanonicalBuildResult(payload: payload, lossyNotes: lossyNotes)
    }
}

public struct CanonicalClaudeStreamBuilder {
    public init() {}

    public func build(event: CanonicalStreamEvent) -> [ClaudeStreamEvent] {
        switch event {
        case .messageStarted(let start):
            return [.messageStart(ClaudeMessageStartEvent(message: ClaudeMessageStart(
                id: start.messageID ?? UUID().uuidString,
                type: "message",
                role: start.role.value,
                model: start.model ?? "claude"
            )))]

        case .contentPartStarted(let start):
            guard let block = makeClaudeStreamStartBlock(from: start) else { return [] }
            return [.contentBlockStart(ClaudeContentBlockStartEvent(
                index: start.index,
                contentBlock: block
            ))]

        case .contentPartDelta(let delta):
            if let textDelta = delta.textDelta {
                switch delta.kind {
                case .text:
                    return [.contentBlockDelta(ClaudeContentBlockDeltaEvent(
                        index: delta.index,
                        delta: .text(ClaudeTextDelta(type: "text_delta", text: textDelta))
                    ))]
                case .reasoning:
                    return [.contentBlockDelta(ClaudeContentBlockDeltaEvent(
                        index: delta.index,
                        delta: .thinking(ClaudeThinkingDelta(thinking: textDelta))
                    ))]
                case .toolCall, .unknown:
                    return []
                }
            }

            if let jsonDelta = delta.jsonDelta {
                return [.contentBlockDelta(ClaudeContentBlockDeltaEvent(
                    index: delta.index,
                    delta: .inputJson(ClaudeInputJsonDelta(type: "input_json_delta", partialJson: jsonDelta))
                ))]
            }

            if delta.kind.value == "reasoning",
               let signature = delta.rawExtensions.first(where: {
                   $0.vendor == "claude" && $0.key == "signature_delta"
               })?.value.value as? String {
                return [.contentBlockDelta(ClaudeContentBlockDeltaEvent(
                    index: delta.index,
                    delta: .signature(ClaudeSignatureDelta(signature: signature))
                ))]
            }

            return []

        case .contentPartStopped(let stop):
            return [.contentBlockStop(ClaudeContentBlockStopEvent(index: stop.index))]

        case .messageDelta(let delta):
            return [.messageDelta(ClaudeMessageDeltaEvent(
                delta: ClaudeMessageDeltaContent(
                    stopReason: delta.stop.flatMap { canonicalClaudeStopReason($0.reason) },
                    stopSequence: delta.stop?.sequence
                ),
                usage: ClaudeUsageDelta(outputTokens: delta.usage?.outputTokens ?? 0)
            ))]

        case .messageStopped:
            return [.messageStop]

        case .error:
            return [.messageDelta(ClaudeMessageDeltaEvent(
                delta: ClaudeMessageDeltaContent(
                    stopReason: "error",
                    stopSequence: nil
                ),
                usage: ClaudeUsageDelta(outputTokens: 0)
            ))]
        }
    }
}

private func makeClaudeContentBlocks(
    from parts: [CanonicalContentPart],
    itemIndex: Int,
    lossyNotes: inout [CanonicalLossyNote]
) -> [ClaudeContentBlock] {
    parts.compactMap { part in
        makeClaudeContentBlock(from: part, itemIndex: itemIndex, lossyNotes: &lossyNotes)
    }
}

private func makeClaudeContentBlock(
    from part: CanonicalContentPart,
    itemIndex: Int,
    lossyNotes: inout [CanonicalLossyNote]
) -> ClaudeContentBlock? {
    switch part {
    case .text(let text):
        return .text(ClaudeTextBlock(text: text.text))

    case .image(let image):
        guard case .base64 = image.source, let mediaType = image.mediaType else {
            appendClaudeLossyNote(
                to: &lossyNotes,
                code: "claude_non_base64_image_skipped",
                message: "Only base64 images are emitted to Claude content blocks; non-base64 canonical image was skipped.",
                itemIndex: itemIndex,
                path: "items[\(itemIndex)].message.parts"
            )
            return nil
        }
        return .image(ClaudeImageBlock(source: ClaudeImageSource(mediaType: mediaType, data: image.data)))

    case .document(let document):
        return .document(makeClaudeDocumentBlock(from: document))

    case .fileRef(let fileRef):
        return .document(ClaudeDocumentBlock(
            source: [
                "type": AnyCodable("file"),
                "file_id": AnyCodable(fileRef.fileID ?? "")
            ],
            title: fileRef.filename
        ))

    case .reasoningText(let reasoning):
        return .thinking(ClaudeThinkingBlock(thinking: reasoning.text))

    case .refusal(let refusal):
        return .text(ClaudeTextBlock(text: refusal.text))

    case .unknown(let unknown):
        appendClaudeLossyNote(
            to: &lossyNotes,
            code: "claude_unknown_part_skipped",
            message: "Unknown canonical content part `\(unknown.type)` was skipped in Claude response builder.",
            itemIndex: itemIndex,
            path: "items[\(itemIndex)].message.parts"
        )
        return nil
    }
}

private func makeClaudeDocumentBlock(from document: CanonicalDocumentPart) -> ClaudeDocumentBlock {
    switch document.source {
    case .fileID(let fileID):
        return ClaudeDocumentBlock(
            source: [
                "type": AnyCodable("file"),
                "file_id": AnyCodable(fileID)
            ],
            title: document.title,
            context: document.context,
            citations: document.citations
        )

    case .inlineText(let text):
        return ClaudeDocumentBlock(
            source: [
                "type": AnyCodable("text"),
                "text": AnyCodable(text)
            ],
            title: document.title,
            context: document.context,
            citations: document.citations
        )

    case .contentParts(let parts):
        let body = extractClaudeDocumentContentText(parts) ?? ""
        return ClaudeDocumentBlock(
            source: [
                "type": AnyCodable("text"),
                "text": AnyCodable(body)
            ],
            title: document.title,
            context: document.context,
            citations: document.citations
        )

    case .url(let url):
        return ClaudeDocumentBlock(
            source: [
                "type": AnyCodable("url"),
                "url": AnyCodable(url)
            ],
            title: document.title,
            context: document.context,
            citations: document.citations
        )

    case .base64(let data, let mediaType):
        var source: [String: AnyCodable] = [
            "type": AnyCodable("base64"),
            "data": AnyCodable(data)
        ]
        if let mediaType {
            source["media_type"] = AnyCodable(mediaType)
        }
        return ClaudeDocumentBlock(
            source: source,
            title: document.title,
            context: document.context,
            citations: document.citations
        )

    case .unknown(let payload):
        if let dictionary = payload.value as? [String: Any] {
            return ClaudeDocumentBlock(
                source: dictionary.mapValues(AnyCodable.init),
                title: document.title,
                context: document.context,
                citations: document.citations
            )
        }
        return ClaudeDocumentBlock(
            source: ["type": AnyCodable("text"), "text": AnyCodable("")],
            title: document.title,
            context: document.context,
            citations: document.citations
        )
    }
}

private func makeClaudeStreamStartBlock(from start: CanonicalStreamContentPartStarted) -> ClaudeContentBlock? {
    switch start.kind {
    case .text:
        return .text(ClaudeTextBlock(text: ""))
    case .reasoning:
        return .thinking(ClaudeThinkingBlock(thinking: ""))
    case .toolCall:
        return .toolUse(ClaudeToolUseBlock(
            id: start.toolCallID ?? "tool_\(start.index)",
            name: start.toolName ?? "tool",
            input: [:]
        ))
    case .unknown:
        return nil
    }
}

private func parseCanonicalToolInput(_ inputJSON: String) throws -> [String: AnyCodable] {
    guard let data = inputJSON.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return json.mapValues(AnyCodable.init)
}

private func canonicalClaudeStopReason(_ reason: CanonicalStopReason) -> String? {
    switch reason {
    case .endTurn:
        return "end_turn"
    case .toolUse:
        return "tool_use"
    case .maxTokens:
        return "max_tokens"
    case .pauseTurn:
        return "pause_turn"
    case .refusal:
        return "refusal"
    case .modelContextWindowExceeded:
        return "model_context_window_exceeded"
    case .error:
        return "error"
    case .unknown(let raw):
        return raw
    }
}

private func extractClaudeDocumentContentText(_ parts: [CanonicalContentPart]) -> String? {
    let text = parts.compactMap { part -> String? in
        switch part {
        case .text(let text):
            return text.text
        case .document(let document):
            switch document.source {
            case .inlineText(let inlineText):
                return inlineText
            case .contentParts(let nested):
                return extractClaudeDocumentContentText(nested)
            default:
                return nil
            }
        default:
            return nil
        }
    }
    .filter { !$0.isEmpty }
    .joined(separator: "\n")
    return text.isEmpty ? nil : text
}

private func appendClaudeLossyNote(
    to notes: inout [CanonicalLossyNote],
    code: String,
    message: String,
    itemIndex: Int? = nil,
    path: String? = nil
) {
    notes.append(CanonicalLossyNote(
        code: code,
        message: message,
        itemIndex: itemIndex,
        path: path
    ))
}
