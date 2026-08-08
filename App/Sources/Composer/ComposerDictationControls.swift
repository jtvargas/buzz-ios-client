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
            // Nothing. Preparing is drawn inside the button that was pressed — see
            // ``MessageComposerView/dictationButton`` — at the owner's word: the answer to a
            // press belongs on the thing that was pressed, and putting it where the waveform
            // will be announces a surface that is not ready to be shown.
            EmptyView()
        case .listening:
            DictationWaveform(levels: levels)
                .frame(height: DictationWaveform.maxHeight)
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

/// A compact amplitude history, not a frequency spectrum.
///
/// # Where these numbers come from
///
/// Measured off the owner's reference at @3x rather than chosen: bars **3pt** wide on a
/// **5pt** pitch — so a 2pt gap, and ink is 60% of the pitch — reaching **28pt** at the
/// loudest. Silence is not a hairline but a **dot**: the bar's floor is its own width, which
/// draws as a circle because the capsule's radius is half that width. That dotted run through
/// the quiet parts is most of what makes the reference read as a considered drawing rather
/// than a level meter.
///
/// # Why the bar count is derived rather than fixed
///
/// The pitch is the constant, not the number of bars, so the drawing keeps its density on any
/// width — a narrower composer shows fewer bars of the same size instead of the same bars
/// stretched. The owner's note was that the waves should read as *more and shorter*, and a
/// fixed count is exactly what stops that being true.
struct DictationWaveform: View {
    let levels: [Float]

    /// Ink width of one bar.
    static let barWidth: CGFloat = 3
    /// Centre-to-centre spacing. `barWidth` of ink and 2 of air.
    static let pitch: CGFloat = 5
    /// The loudest a bar is drawn.
    static let maxHeight: CGFloat = 28

    /// How many bars fit a given width — the model's sample budget, so the buffer holds
    /// exactly what is drawn and no history is kept that nobody sees.
    static func barCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width + pitch - Self.barWidth) / pitch))
    }

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            // Right-aligned: the newest sample is the one under the reader's eye, and a
            // partially filled buffer should grow leftward from `now` rather than sit in the
            // left corner while the rest of the track stays blank.
            let count = min(levels.count, Self.barCount(forWidth: size.width))
            let drawn = levels.suffix(count)
            let used = CGFloat(count) * Self.pitch - (Self.pitch - Self.barWidth)
            let origin = size.width - used

            for (offset, level) in drawn.enumerated() {
                let height = max(
                    Self.barWidth,
                    min(Self.maxHeight, size.height) * CGFloat(level)
                )
                let rect = CGRect(
                    x: origin + CGFloat(offset) * Self.pitch,
                    y: (size.height - height) / 2,
                    width: Self.barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                    with: .color(.accentColor.opacity(0.92))
                )
            }
        }
    }
}
