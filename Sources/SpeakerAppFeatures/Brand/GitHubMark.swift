import SwiftUI

/// The GitHub wordmark's Octocat outline, normalized to its 98x96 source box.
/// SF Symbols has no GitHub glyph, so this brand shape carries the path; the
/// displaying surface owns fill colour and size.
struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 41.4395, y: 69.3848))
        path.addCurve(
            to: CGPoint(x: 19.9062, y: 46.9902),
            control1: CGPoint(x: 28.8066, y: 67.8535),
            control2: CGPoint(x: 19.9062, y: 58.7617)
        )
        path.addCurve(
            to: CGPoint(x: 24.5, y: 33.5918),
            control1: CGPoint(x: 19.9062, y: 42.2051),
            control2: CGPoint(x: 21.6289, y: 37.0371)
        )
        path.addCurve(
            to: CGPoint(x: 24.8828, y: 20.959),
            control1: CGPoint(x: 23.2559, y: 30.4336),
            control2: CGPoint(x: 23.4473, y: 23.7344)
        )
        path.addCurve(
            to: CGPoint(x: 36.9414, y: 25.2656),
            control1: CGPoint(x: 28.7109, y: 20.4805),
            control2: CGPoint(x: 33.8789, y: 22.4902)
        )
        path.addCurve(
            to: CGPoint(x: 49.0957, y: 23.543),
            control1: CGPoint(x: 40.5781, y: 24.1172),
            control2: CGPoint(x: 44.4062, y: 23.543)
        )
        path.addCurve(
            to: CGPoint(x: 61.0586, y: 25.1699),
            control1: CGPoint(x: 53.7852, y: 23.543),
            control2: CGPoint(x: 57.6133, y: 24.1172)
        )
        path.addCurve(
            to: CGPoint(x: 73.1172, y: 20.959),
            control1: CGPoint(x: 64.0254, y: 22.4902),
            control2: CGPoint(x: 69.2891, y: 20.4805)
        )
        path.addCurve(
            to: CGPoint(x: 73.4043, y: 33.4961),
            control1: CGPoint(x: 74.457, y: 23.543),
            control2: CGPoint(x: 74.6484, y: 30.2422)
        )
        path.addCurve(
            to: CGPoint(x: 78.0937, y: 46.9902),
            control1: CGPoint(x: 76.4668, y: 37.1328),
            control2: CGPoint(x: 78.0937, y: 42.0137)
        )
        path.addCurve(
            to: CGPoint(x: 56.3691, y: 69.2891),
            control1: CGPoint(x: 78.0937, y: 58.7617),
            control2: CGPoint(x: 69.1934, y: 67.6621)
        )
        path.addCurve(
            to: CGPoint(x: 61.8242, y: 81.252),
            control1: CGPoint(x: 59.623, y: 71.3945),
            control2: CGPoint(x: 61.8242, y: 75.9883)
        )
        path.addLine(to: CGPoint(x: 61.8242, y: 91.2051))
        path.addCurve(
            to: CGPoint(x: 67.0879, y: 94.5547),
            control1: CGPoint(x: 61.8242, y: 94.0762),
            control2: CGPoint(x: 64.2168, y: 95.7031)
        )
        path.addCurve(
            to: CGPoint(x: 98, y: 49.1914),
            control1: CGPoint(x: 84.4102, y: 87.9512),
            control2: CGPoint(x: 98, y: 70.6289)
        )
        path.addCurve(
            to: CGPoint(x: 48.9043, y: 0),
            control1: CGPoint(x: 98, y: 22.1074),
            control2: CGPoint(x: 75.9883, y: 0)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: 49.1914),
            control1: CGPoint(x: 21.8203, y: 0),
            control2: CGPoint(x: 0, y: 22.1074)
        )
        path.addCurve(
            to: CGPoint(x: 31.6777, y: 94.6504),
            control1: CGPoint(x: 0, y: 70.4375),
            control2: CGPoint(x: 13.4941, y: 88.0469)
        )
        path.addCurve(
            to: CGPoint(x: 36.75, y: 91.3008),
            control1: CGPoint(x: 34.2617, y: 95.6074),
            control2: CGPoint(x: 36.75, y: 93.8848)
        )
        path.addLine(to: CGPoint(x: 36.75, y: 83.6445))
        path.addCurve(
            to: CGPoint(x: 32.1562, y: 84.6016),
            control1: CGPoint(x: 35.4102, y: 84.2188),
            control2: CGPoint(x: 33.6875, y: 84.6016)
        )
        path.addCurve(
            to: CGPoint(x: 19.4277, y: 74.7441),
            control1: CGPoint(x: 25.8398, y: 84.6016),
            control2: CGPoint(x: 22.1074, y: 81.1563)
        )
        path.addCurve(
            to: CGPoint(x: 15.0254, y: 70.3418),
            control1: CGPoint(x: 18.375, y: 72.1602),
            control2: CGPoint(x: 17.2266, y: 70.6289)
        )
        path.addCurve(
            to: CGPoint(x: 13.4941, y: 69.1934),
            control1: CGPoint(x: 13.877, y: 70.2461),
            control2: CGPoint(x: 13.4941, y: 69.7676)
        )
        path.addCurve(
            to: CGPoint(x: 17.3223, y: 67.1836),
            control1: CGPoint(x: 13.4941, y: 68.0449),
            control2: CGPoint(x: 15.4082, y: 67.1836)
        )
        path.addCurve(
            to: CGPoint(x: 24.9785, y: 72.4473),
            control1: CGPoint(x: 20.0977, y: 67.1836),
            control2: CGPoint(x: 22.4902, y: 68.9063)
        )
        path.addCurve(
            to: CGPoint(x: 31.2949, y: 76.4668),
            control1: CGPoint(x: 26.8926, y: 75.2227),
            control2: CGPoint(x: 28.9023, y: 76.4668)
        )
        path.addCurve(
            to: CGPoint(x: 37.4199, y: 73.4043),
            control1: CGPoint(x: 33.6875, y: 76.4668),
            control2: CGPoint(x: 35.2187, y: 75.6055)
        )
        path.addCurve(
            to: CGPoint(x: 41.4395, y: 69.3848),
            control1: CGPoint(x: 39.0469, y: 71.7773),
            control2: CGPoint(x: 40.291, y: 70.3418)
        )
        path.closeSubpath()

        let scale = min(rect.width / 98, rect.height / 96)
        let transform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: rect.midX - 49 * scale,
            ty: rect.midY - 48 * scale
        )
        return path.applying(transform)
    }
}
