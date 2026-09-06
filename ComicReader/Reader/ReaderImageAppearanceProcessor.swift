import CoreGraphics
import Foundation

/// 仅处理管线已降采样的展示图，不访问或改写来源。纯色边缘探测限制在 256 像素。
actor ReaderImageAppearanceProcessor {
    static let shared = ReaderImageAppearanceProcessor()

    func process(_ image: CGImage, trimsWhitespace: Bool, quarterTurns: Int) throws -> CGImage {
        try Task.checkCancellation()
        let cropped = trimsWhitespace ? Self.trimmed(image) : image
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return cropped }
        let width = turns.isMultiple(of: 2) ? cropped.width : cropped.height
        let height = turns.isMultiple(of: 2) ? cropped.height : cropped.width
        guard let context = Self.context(width: width, height: height) else { return cropped }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: CGFloat(turns) * .pi / 2)
        context.draw(cropped, in: CGRect(
            x: -CGFloat(cropped.width) / 2, y: -CGFloat(cropped.height) / 2,
            width: CGFloat(cropped.width), height: CGFloat(cropped.height)
        ))
        try Task.checkCancellation()
        return context.makeImage() ?? cropped
    }

    private static func trimmed(_ image: CGImage) -> CGImage {
        let scale = min(1, 256 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = context(width: width, height: height) else { return image }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        let background = (0..<3).map { Int(bytes[$0]) }
        func matchesBackground(x: Int, y: Int) -> Bool {
            let index = y * context.bytesPerRow + x * 4
            return (0..<3).allSatisfy { abs(Int(bytes[index + $0]) - background[$0]) <= 10 }
        }
        // 四角颜色不一致时不推断纯色背景，保留整页以免误裁漫画内容。
        guard matchesBackground(x: width - 1, y: 0),
              matchesBackground(x: 0, y: height - 1),
              matchesBackground(x: width - 1, y: height - 1) else { return image }
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width {
                if !matchesBackground(x: x, y: y) {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        guard right >= left, bottom >= top else { return image }
        // 保留探测图上两像素的安全边，防止裁掉淡色边缘。
        left = max(0, left - 2); top = max(0, top - 2)
        right = min(width - 1, right + 2); bottom = min(height - 1, bottom + 2)
        let rect = CGRect(
            x: CGFloat(left) * CGFloat(image.width) / CGFloat(width),
            y: CGFloat(top) * CGFloat(image.height) / CGFloat(height),
            width: CGFloat(right - left + 1) * CGFloat(image.width) / CGFloat(width),
            height: CGFloat(bottom - top + 1) * CGFloat(image.height) / CGFloat(height)
        ).integral
        return image.cropping(to: rect) ?? image
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
