import SwiftUI

// Countdown dial: sixty ticks around the rim and a thin arc of what's left over
// them. The ticks count out the current minute, the arc the whole interval — it
// reads from across the room and up close.
//
// Shared by the timer and the pomodoro: the same shape has to mean the same thing,
// and two tiles side by side with different dials would read as two programs.
struct TileDial: View {
    /// 1 at the start of the interval, 0 at its end
    let remaining: Double
    /// Share of the current minute — drives the ticks even on a long interval
    let secondsShare: Double
    let tint: Color

    @Environment(\.theme) private var theme

    private static let ticks = 60
    private static let lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            // Tick marks: the ones already passed in the current minute dim out
            GeometryReader { geo in
                let radius = min(geo.size.width, geo.size.height) / 2
                ForEach(0..<Self.ticks, id: \.self) { index in
                    let passed = Double(index) / Double(Self.ticks) <= secondsShare
                    Capsule()
                        .fill(
                            passed
                                ? tint.opacity(0.55)
                                : theme.textMuted.color.opacity(0.18))
                        .frame(width: 1.5, height: index % 5 == 0 ? 7 : 4)
                        .offset(y: -radius + 12)
                        .rotationEffect(.degrees(Double(index) / Double(Self.ticks) * 360))
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }

            // Track and remainder arc: kept thin so the dial doesn't turn into a donut
            Circle()
                .inset(by: 22)
                .stroke(theme.textMuted.color.opacity(0.14), lineWidth: Self.lineWidth)

            Circle()
                .inset(by: 22)
                .trim(from: 0, to: max(remaining, 0.001))
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.65), tint, tint.opacity(0.65)],
                        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Linear and exactly in step with the tick: easeOut on a value that
                // changes every second keeps chasing itself.
                // No shadow — it was being recomputed on every animation frame
                .animation(.linear(duration: 1), value: remaining)
        }
    }
}
