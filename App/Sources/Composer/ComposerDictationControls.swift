import SwiftUI

/// The composer's second row while dictation owns the microphone. Its metrics match the
/// ordinary controls row exactly, so changing modes never moves the field or conversation.
struct ComposerDictationControls: View {
    let phase: ComposerDictationModel.Phase
    let levels: [Float]
    let preparationProgress: Double?
    let controlDiameter: CGFloat
    let hitTarget: CGFloat
    let cancel: () -> Void
    let finish: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.hiveSymbol(.body, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: controlDiameter, height: controlDiameter)
                    .frame(width: hitTarget, height: hitTarget)
            }
            .buttonStyle(.hivePress(.control, in: .circle))
            .accessibilityLabel("Cancel dictation")

            center
                .frame(maxWidth: .infinity)

            Button(action: finish) {
                Image(systemName: "checkmark")
                    .font(.hiveSymbol(.body, weight: .semibold))
                    .foregroundStyle(phase == .listening ? Color.black : Color.secondary)
                    .frame(width: controlDiameter, height: controlDiameter)
                    .background(finishDisc, in: .circle)
                    .frame(width: hitTarget, height: hitTarget)
            }
            .buttonStyle(.hivePress(.control, in: .circle))
            .disabled(phase != .listening)
            .accessibilityLabel("Finish dictation")
        }
        .frame(minHeight: hitTarget)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var center: some View {
        switch phase {
        case .preparing:
            VStack(spacing: 3) {
                Text("Preparing dictation")
                    .font(.hive(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let preparationProgress {
                    ProgressView(value: preparationProgress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
        case .listening:
            DictationWaveform(levels: levels)
                .frame(height: 26)
                .accessibilityElement()
                .accessibilityLabel("Listening")
        case .finishing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Finishing dictation")
        case .idle:
            EmptyView()
        }
    }

    private var finishDisc: AnyShapeStyle {
        phase == .listening ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)
    }
}

/// A compact amplitude history, not a frequency spectrum. One Canvas keeps the fixed
/// 24-bar audiogram cheap while the model replaces samples at a capped paint rate.
private struct DictationWaveform: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let spacing: CGFloat = 2
            let width = max(
                1,
                (size.width - spacing * CGFloat(levels.count - 1)) / CGFloat(levels.count)
            )
            for (index, level) in levels.enumerated() {
                let height = max(2, size.height * CGFloat(0.12 + level * 0.88))
                let rect = CGRect(
                    x: CGFloat(index) * (width + spacing),
                    y: (size.height - height) / 2,
                    width: width,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: .color(.accentColor.opacity(0.92))
                )
            }
        }
    }
}
