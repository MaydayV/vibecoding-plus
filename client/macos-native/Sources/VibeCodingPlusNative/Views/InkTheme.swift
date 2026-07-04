import SwiftUI
// MARK: - Theme

enum InkTheme {
    // 墨水屏黑白主色：accent 用近黑代替蓝色
    static let accent = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let paper = Color(red: 0.97, green: 0.97, blue: 0.96)
    // 状态用灰阶而非彩色：success 深黑、warning 中深灰、danger 深灰
    static let success = Color(red: 0.18, green: 0.20, blue: 0.18)
    static let warning = Color(red: 0.42, green: 0.40, blue: 0.32)
    static let danger = Color(red: 0.30, green: 0.26, blue: 0.26)
    // 像素点阵纹理色
    static let dither = Color(red: 0.55, green: 0.55, blue: 0.54)
}

/// 墨水屏点阵(dither)肌理：用稀疏小方点模拟墨水屏像素颗粒
struct InkDitherBackground: View {
    var opacity: Double = 0.5
    var step: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let dotSize: CGFloat = 1
            var y: CGFloat = step / 2
            var row = 0
            while y < size.height {
                let xOffset: CGFloat = (row % 2 == 0) ? 0 : step / 2
                var x: CGFloat = step / 2 + xOffset
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    context.fill(Path(rect), with: .color(InkTheme.dither.opacity(opacity)))
                    x += step
                }
                y += step
                row += 1
            }
        }
    }
}

enum MetricTone {
    case accent
    case success
    case idle
}
