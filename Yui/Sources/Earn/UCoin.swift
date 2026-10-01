import SwiftUI

/// The $U coin (YUI-210): a small drawn gold coin with a U on its face, never the letters.
/// Drawn the way the PROP-5 hero draws it (site/app/proposals/EarnHero.js), on a 24 point grid.
struct UCoin: View {
    var size: CGFloat = 18

    var body: some View {
        Canvas { ctx, box in
            let k = box.width / 24
            func dot(_ cy: Double, _ r: Double) -> Path {
                Path(ellipseIn: CGRect(x: (12 - r) * k, y: (cy - r) * k, width: 2 * r * k, height: 2 * r * k))
            }
            ctx.fill(dot(12.8, 10.2), with: .color(Color(red: 0.851, green: 0.584, blue: 0.110)))
            ctx.fill(dot(11.6, 10.2), with: .color(Color(red: 1, green: 0.784, blue: 0.239)))
            ctx.stroke(dot(11.6, 7.6), with: .color(Color(red: 0.910, green: 0.651, blue: 0.149)), lineWidth: 1.3 * k)
            var u = Path()
            u.move(to: CGPoint(x: 8.9 * k, y: 7.6 * k))
            u.addLine(to: CGPoint(x: 8.9 * k, y: 12.2 * k))
            u.addArc(center: CGPoint(x: 12 * k, y: 12.2 * k), radius: 3.1 * k,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            u.addLine(to: CGPoint(x: 15.1 * k, y: 7.6 * k))
            ctx.stroke(u, with: .color(Color(red: 0.541, green: 0.353, blue: 0)),
                       style: StrokeStyle(lineWidth: 2.1 * k, lineCap: .round))
            var shine = Path()
            shine.addArc(center: CGPoint(x: 12 * k, y: 11.6 * k), radius: 6.6 * k,
                         startAngle: .degrees(205), endAngle: .degrees(245), clockwise: false)
            ctx.stroke(shine, with: .color(Color(red: 1, green: 0.945, blue: 0.761)),
                       style: StrokeStyle(lineWidth: 1.3 * k, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
