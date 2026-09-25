import SwiftUI

/// The voice while hold to talk listens: a bar per loudness peak, newest on the right,
/// sliding left as you speak (TestFlight feedback AFxu7cyMxK1BmzLnKcwsPzw).
/// Reduce Motion gets one still bar that fills with the loudness instead.
struct TalkWaveform: View {
    let levels: [Double]
    let level: Double
    let color: Color
    let track: Color
    var reduceMotion = false

    var body: some View {
        if reduceMotion {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule().fill(color).frame(width: max(6, g.size.width * level))
                }
            }
            .frame(height: 6)
            .frame(maxHeight: 24)
            .accessibilityHidden(true)
        } else {
            let padded = Array(repeating: 0.0, count: max(PushToTalk.bars - levels.count, 0)) + levels.suffix(PushToTalk.bars)
            HStack(alignment: .center, spacing: 2) {
                ForEach(padded.indices, id: \.self) { i in
                    Capsule()
                        .fill(padded[i] > 0 ? color : track)
                        .frame(width: 3, height: 4 + 20 * padded[i])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 24, alignment: .trailing)
            .clipped()
            .animation(.easeOut(duration: 0.08), value: levels)
            .accessibilityHidden(true)
        }
    }
}
