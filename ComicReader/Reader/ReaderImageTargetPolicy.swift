import CoreGraphics

enum ReaderImageTargetPolicy {
    private static let pixelBucketSize = 256

    static func target(
        displaySize: CGSize,
        displayScale: CGFloat,
        imageScale: CGFloat = 1
    ) -> ReaderImageTarget? {
        guard displaySize.width.isFinite,
              displaySize.height.isFinite,
              displayScale.isFinite,
              imageScale.isFinite,
              displaySize.width > 0,
              displaySize.height > 0,
              displayScale > 0,
              imageScale > 0 else {
            return nil
        }

        let maximumDimension = max(displaySize.width, displaySize.height)
        let maximumPixelSize = ReaderImageTarget.maximumDecodedPixelSize
        let effectiveImageScale = max(imageScale, 1)

        // 先比较商，避免两个很大的有限 CGFloat 相乘后溢出为 infinity。
        let maximumSafeDimension = CGFloat(maximumPixelSize)
            / displayScale / effectiveImageScale
        if maximumDimension >= maximumSafeDimension {
            return try? ReaderImageTarget(maximumPixelSize: maximumPixelSize)
        }

        let scaledMaximumDimension = maximumDimension
            * displayScale
            * effectiveImageScale
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
