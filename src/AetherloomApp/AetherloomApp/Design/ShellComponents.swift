import AetherloomBridge
import AetherloomCore
import AppKit
import SwiftUI

struct ToneDot: View {
    var tone: Tone

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: 8, height: 8)
            .shadow(color: tone.color.opacity(0.6), radius: 3)
            .accessibilityHidden(true)
    }
}

struct PlaceholderChip: View {
    var text = "Coming soon"

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.18), lineWidth: 0.5))
            .fixedSize()
            .accessibilityLabel("Coming soon. \(text)")
    }
}

struct PathText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var path: String

    @State private var copied = false

    init(_ path: String) {
        self.path = path
    }

    init(_ path: SyncPath) {
        self.path = path.rawValue
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            copied = true
        } label: {
            HStack(spacing: 5) {
                Text(path)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if copied {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 24)
        .help(copied ? "Copied \(path)" : "\(path) — click to copy")
        .accessibilityLabel("Copy path \(path)")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth) {
                copied = false
            }
        }
    }
}

struct CountAcknowledgeRow: View {
    enum Kind {
        case trash
        case conflicts
    }

    var kind: Kind
    var count: Int
    @Binding var isAcknowledged: Bool

    var body: some View {
        Toggle(isOn: $isAcknowledged) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                switch kind {
                case .trash:
                    Text("Move")
                    countText
                    Text(count == 1
                         ? "item to trash (recoverable from each provider's trash)"
                         : "items to trash (recoverable from each provider's trash)")
                case .conflicts:
                    countText
                    Text(count == 1
                         ? "conflict — both versions preserved"
                         : "conflicts — both versions preserved")
                }
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(accessibilityText)
    }

    private var countText: some View {
        Text(count.formatted())
            .fontWeight(.semibold)
            .monospacedDigit()
            .liveNumericTransition()
    }

    private var accessibilityText: String {
        switch kind {
        case .trash:
            "Acknowledge moving \(count.formatted()) \(count == 1 ? "item" : "items") to trash, recoverable from each provider's trash"
        case .conflicts:
            "Acknowledge \(count.formatted()) \(count == 1 ? "conflict" : "conflicts"), both versions preserved"
        }
    }
}

struct AdviceChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var recommendation: String?
    var confidence: AdviceConfidence?
    var rationale: String
    var attribution: String
    var versionNotes: [AdviceVersionNoteDisplay]
    var onDismiss: (() -> Void)?

    @State private var isExpanded = false

    init(
        recommendation: String? = nil,
        confidence: AdviceConfidence? = nil,
        rationale: String,
        attribution: String = "Suggested on-device by Aetherloom Heuristic Advisor",
        versionNotes: [AdviceVersionNoteDisplay] = [],
        onDismiss: (() -> Void)? = nil
    ) {
        self.recommendation = recommendation
        self.confidence = confidence
        self.rationale = rationale
        self.attribution = attribution
        self.versionNotes = versionNotes
        self.onDismiss = onDismiss
    }

    init(advice: AdviceDisplay, onDismiss: (() -> Void)? = nil) {
        self.init(
            recommendation: Self.summary(for: advice),
            confidence: advice.confidence,
            rationale: advice.rationale,
            attribution: advice.attribution,
            versionNotes: advice.perVersionNotes,
            onDismiss: onDismiss
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.accent)
                    Text(recommendation.map { "Suggestion: \($0)" } ?? "Suggestion")
                        .font(.caption.weight(.semibold))
                    if let confidence {
                        Circle()
                            .fill(confidenceColor(confidence))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text("\(confidence.rawValue) confidence")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 24)
            .accessibilityLabel(isExpanded ? "Collapse suggestion" : "Expand suggestion")

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    Text(rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(versionNotes) { note in
                        Text("\(note.location.displayName): \(note.note)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(attribution). On-device suggestion — you decide.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if let onDismiss {
                            Button("Dismiss", action: onDismiss)
                                .font(.caption)
                                .buttonStyle(.link)
                                .frame(minHeight: 24)
                                .accessibilityLabel("Dismiss suggestion for this conflict")
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    private func confidenceColor(_ confidence: AdviceConfidence) -> Color {
        switch confidence {
        case .low: .secondary
        case .medium: Theme.accent.opacity(0.72)
        case .high: .teal
        }
    }

    private static func summary(for advice: AdviceDisplay) -> String {
        switch advice.recommendation {
        case .keepBoth:
            "keep both versions"
        case .makeCanonical:
            "keep the \(advice.recommendationLabel.replacingOccurrences(of: "Choose ", with: "")) version"
        }
    }
}

struct RunResultToast: View {
    struct Model: Identifiable, Hashable {
        var id: UUID { runID }
        var runID: UUID
        var title: String
        var detail: String
        var tone: Tone

        init(summary: SyncRunSummary) {
            runID = summary.runID
            if !summary.failedOperations.isEmpty || summary.outcome.isFailure {
                detail = "\(summary.appliedOperations.count) applied, \(summary.failedOperations.count) failed — see Activity"
            } else {
                detail = "\(summary.appliedOperations.count) applied · \(summary.skippedOperations.count) skipped · 0 failed"
            }
            switch summary.outcome {
            case .completed:
                title = "Sync complete"
                tone = summary.failedOperations.isEmpty ? .healthy : .attention
            case .held:
                title = "Needs review"
                tone = .attention
            case .refused:
                title = "Paused for safety"
                tone = .paused
            case .stoppedForReplan:
                title = "Files changed — preview again"
                tone = .attention
            case .cancelled:
                title = "Sync cancelled"
                tone = .neutral
            case .failed:
                title = "Sync stopped"
                tone = .attention
            }
        }
    }

    var model: Model
    var openActivity: () -> Void
    var dismiss: () -> Void

    var body: some View {
        Button(action: openActivity) {
            HStack(spacing: 10) {
                Image(systemName: model.tone.systemImage)
                    .foregroundStyle(model.tone.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.subheadline.weight(.semibold))
                    Text(model.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(model.tone.color.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.title). \(model.detail). Open Activity.")
        .task(id: model.id) {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}

private extension SyncRunOutcome {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

#Preview("Shell components") {
    VStack(spacing: 20) {
        HStack {
            ToneDot(tone: .healthy)
            Text("Everything in sync")
        }
        PlaceholderChip()
        RunResultToast(
            model: .init(
                summary: SyncRunSummary(
                    runID: UUID(),
                    syncSetID: UUID(),
                    outcome: .completed
                )
            ),
            openActivity: {},
            dismiss: {}
        )
    }
    .padding(30)
}
