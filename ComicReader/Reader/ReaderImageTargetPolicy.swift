import CoreGraphics

enum ReaderImageTargetPolicy {
    private static let pixelBucketSize = 256

    static func target(
        displaySize: CGSize,
        displayScale: CGFloat
    ) -> ReaderImageTarget? {
        guard displaySize.width.isFinite,
              displaySize.height.isFinite,
              displayScale.isFinite,
              displaySize.width > 0,
              displaySize.height > 0,
              displayScale > 0 else {
            return nil
        }

        let maximumDimension = max(displaySize.width, displaySize.height)
        let maximumPixelSize = ReaderImageTarget.maximumDecodedPixelSize

        // 先比较商，避免两个很大的有限 CGFloat 相乘后溢出为 infinity。
        if maximumDimension >= CGFloat(maximumPixelSize) / displayScale {
            return try? ReaderImageTarget(maximumPixelSize: maximumPixelSize)
        }

        let scaledMaximumDimension = maximumDimension * displayScale
        let bucketCount = Int(
            (scaledMaximumDimension / CGFloat(pixelBucketSize)).rounded(.up)
        )
        let bucketedPixelSize = max(
            pixelBucketSize,
            bucketCount * pixelBucketSize
        )

        return try? ReaderImageTarget(
            maximumPixelSize: min(bucketedPixelSize, maximumPixelSize)
        )
    }
}
