import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// High-precision CoreGraphics + CoreImage annotation compositor reconstructing `ShareX.ImageEditor` rendering:
/// renders Blur (`CIGaussianBlur`), Pixelate (`CIPixellate`), Spotlight, Arrow, Rectangle, Ellipse, Line,
/// Freehand, Highlight, Text, Step Number badges, and Crop at full pixel resolution.
public enum AnnotationRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Flattens `annotations` onto `baseImage` (in top-left pixel coordinates) and returns a crisp `CGImage`.
    public static func render(baseImage: CGImage, annotations: [AnnotationItem]) -> CGImage {
        let w = baseImage.width
        let h = baseImage.height
        guard w > 0, h > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: w * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return baseImage
        }

        // Draw base image in standard CGContext bottom-left space first
        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Step 1: Apply raster effect annotations (Blur, Pixelate, Spotlight, SmartEraser, Magnify)
        var currentImage = ctx.makeImage() ?? baseImage
        for item in annotations {
            switch item.tool {
            case .blur, .pixelate:
                currentImage = applyRegionFilter(to: currentImage, item: item)
            case .spotlight:
                currentImage = applySpotlight(to: currentImage, rectTopLeft: item.boundingRect)
            case .smartEraser:
                currentImage = applySmartEraser(to: currentImage, rectTopLeft: item.boundingRect)
            case .magnify:
                currentImage = applyMagnifyLoupe(to: currentImage, item: item)
            default:
                break
            }
        }

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(currentImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Flip context to top-left origin so all vector/text annotations share exact image pixel coordinates
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1.0, y: -1.0)

        for item in annotations {
            drawVectorAnnotation(item, in: ctx, canvasSize: CGSize(width: w, height: h))
        }

        ctx.restoreGState()

        var finalImage = ctx.makeImage() ?? currentImage

        // Apply terminal crop if any crop annotation exists
        if let cropItem = annotations.last(where: { $0.tool == .crop }) {
            let cropRect = cropItem.boundingRect.intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
            if cropRect.width >= 4, cropRect.height >= 4, let cropped = finalImage.cropping(to: cropRect) {
                finalImage = cropped
            }
        }

        return finalImage
    }

    private static func applyRegionFilter(to image: CGImage, item: AnnotationItem) -> CGImage {
        let imgBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let topLeftRect = item.boundingRect.intersection(imgBounds).integral
        guard topLeftRect.width >= 2, topLeftRect.height >= 2 else { return image }

        // CIImage uses bottom-left origin
        let ciRect = CGRect(
            x: topLeftRect.minX,
            y: CGFloat(image.height) - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        )

        let ciInput = CIImage(cgImage: image)
        let clamped = ciInput.clampedToExtent()
        let filtered: CIImage?

        if item.tool == .blur {
            let filter = CIFilter(name: "CIGaussianBlur")
            filter?.setValue(clamped, forKey: kCIInputImageKey)
            filter?.setValue(max(4.0, item.effectIntensity), forKey: kCIInputRadiusKey)
            filtered = filter?.outputImage?.cropped(to: ciInput.extent)
        } else {
            let filter = CIFilter(name: "CIPixellate")
            filter?.setValue(clamped, forKey: kCIInputImageKey)
            filter?.setValue(max(6.0, item.effectIntensity), forKey: kCIInputScaleKey)
            filtered = filter?.outputImage?.cropped(to: ciInput.extent)
        }

        guard let effectPatch = filtered?.cropped(to: ciRect) else { return image }
        let composited = effectPatch.composited(over: ciInput)
        return ciContext.createCGImage(composited, from: ciInput.extent) ?? image
    }

    private static func applySpotlight(to image: CGImage, rectTopLeft: CGRect) -> CGImage {
        let w = image.width
        let h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(image, in: full)
        ctx.setFillColor(CGColor(gray: 0.0, alpha: 0.58))
        ctx.fill(full)

        let cgSpotlight = CGRect(
            x: rectTopLeft.minX,
            y: CGFloat(h) - rectTopLeft.maxY,
            width: rectTopLeft.width,
            height: rectTopLeft.height
        ).intersection(full)

        if cgSpotlight.width > 1, cgSpotlight.height > 1, let sub = image.cropping(to: rectTopLeft.intersection(full)) {
            ctx.draw(sub, in: cgSpotlight)
        }
        return ctx.makeImage() ?? image
    }

    public static func drawVectorAnnotation(_ item: AnnotationItem, in ctx: CGContext, canvasSize: CGSize) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch item.tool {
        case .select, .blur, .pixelate, .spotlight, .smartEraser, .magnify, .crop:
            break

        case .speechBalloon:
            let r = item.boundingRect
            guard r.width >= 20, r.height >= 20 else { break }
            drawSpeechBalloon(item: item, rect: r, in: ctx)

        case .line:
            ctx.setStrokeColor(item.color.cgColor)
            ctx.setLineWidth(item.strokeWidth)
            ctx.move(to: item.startPoint)
            ctx.addLine(to: item.endPoint)
            ctx.strokePath()

        case .arrow:
            drawArrow(from: item.startPoint, to: item.endPoint, color: item.color.cgColor, strokeWidth: item.strokeWidth, in: ctx)

        case .rectangle:
            let r = item.boundingRect
            guard r.width >= 1, r.height >= 1 else { break }
            if item.filled {
                ctx.setFillColor(item.color.cgColor)
                ctx.fill(r)
            } else {
                ctx.setStrokeColor(item.color.cgColor)
                ctx.setLineWidth(item.strokeWidth)
                ctx.stroke(r)
            }

        case .ellipse:
            let r = item.boundingRect
            guard r.width >= 1, r.height >= 1 else { break }
            if item.filled {
                ctx.setFillColor(item.color.cgColor)
                ctx.fillEllipse(in: r)
            } else {
                ctx.setStrokeColor(item.color.cgColor)
                ctx.setLineWidth(item.strokeWidth)
                ctx.strokeEllipse(in: r)
            }

        case .highlight:
            let r = item.boundingRect
            guard r.width >= 1, r.height >= 1 else { break }
            let hi = RGBAColor(r: item.color.r, g: item.color.g, b: item.color.b, a: 0.36)
            ctx.setFillColor(hi.cgColor)
            ctx.fill(r)

        case .freehand:
            guard item.freehandPoints.count >= 2 else { break }
            ctx.setStrokeColor(item.color.cgColor)
            ctx.setLineWidth(item.strokeWidth)
            ctx.move(to: item.freehandPoints[0])
            for pt in item.freehandPoints.dropFirst() {
                ctx.addLine(to: pt)
            }
            ctx.strokePath()

        case .stepNumber:
            let radius = max(16.0, item.fontSize * 0.82)
            let circleRect = CGRect(
                x: item.startPoint.x - radius,
                y: item.startPoint.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: CGColor(gray: 0, alpha: 0.45))
            ctx.setFillColor(item.color.cgColor)
            ctx.fillEllipse(in: circleRect)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 0.92))
            ctx.setLineWidth(2.2)
            ctx.strokeEllipse(in: circleRect)

            drawTopLeftText(
                "\(item.stepValue)",
                center: item.startPoint,
                fontSize: radius * 1.05,
                bold: true,
                color: .white,
                in: ctx
            )

        case .text:
            let content = item.text.isEmpty ? "Text" : item.text
            drawTopLeftLabelBox(
                content,
                origin: item.startPoint,
                fontSize: item.fontSize,
                fgColor: .white,
                bgColor: item.color.nsColor.withAlphaComponent(0.88),
                in: ctx
            )
        }
    }

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        color: CGColor,
        strokeWidth: CGFloat,
        in ctx: CGContext
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length >= 2 else { return }

        let headLength = max(strokeWidth * 3.8, 16.0)
        let headAngle: CGFloat = .pi / 6.5
        let angle = atan2(dy, dx)

        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * (headLength * 0.65),
            y: end.y - sin(angle) * (headLength * 0.65)
        )

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setStrokeColor(color)
        ctx.setLineWidth(strokeWidth)
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        let p1 = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let p2 = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        ctx.setFillColor(color)
        ctx.move(to: end)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawTopLeftText(
        _ string: String,
        center: CGPoint,
        fontSize: CGFloat,
        bold: Bool,
        color: NSColor,
        in ctx: CGContext
    ) {
        let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let attrStr = NSAttributedString(string: string, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        ctx.saveGState()
        ctx.translateBy(x: center.x - lineWidth * 0.5, y: center.y + (ascent - descent) * 0.5)
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawTopLeftLabelBox(
        _ string: String,
        origin: CGPoint,
        fontSize: CGFloat,
        fgColor: NSColor,
        bgColor: NSColor,
        in ctx: CGContext
    ) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fgColor,
        ]
        let attrStr = NSAttributedString(string: string, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textW = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textH = ascent + descent
        let padX: CGFloat = 10
        let padY: CGFloat = 6

        let pill = CGRect(x: origin.x, y: origin.y, width: textW + padX * 2, height: textH + padY * 2)
        let path = CGPath(roundedRect: pill, cornerWidth: 8, cornerHeight: 8, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: CGColor(gray: 0, alpha: 0.32))
        ctx.addPath(path)
        ctx.setFillColor(bgColor.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: pill.minX + padX, y: pill.minY + padY + ascent)
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Reconstructs `ShareX.ImageEditor` `SmartEraserAnnotation`: samples surrounding border pixel color
    /// and fills the target rectangle seamlessly so sensitive text on flat/UI backgrounds disappears cleanly.
    private static func applySmartEraser(to image: CGImage, rectTopLeft: CGRect) -> CGImage {
        let w = image.width
        let h = image.height
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let target = rectTopLeft.intersection(bounds).integral
        guard target.width >= 2, target.height >= 2 else { return image }

        // Sample pixel just outside top-left corner of erased region
        let sampleX = max(0, min(w - 1, Int(target.minX) - 2))
        let sampleY = max(0, min(h - 1, Int(target.minY) - 2))
        var px: [UInt8] = [255, 255, 255, 255]
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let single = image.cropping(to: CGRect(x: sampleX, y: sampleY, width: 1, height: 1)),
           let sCtx = CGContext(
               data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
               space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
           ) {
            sCtx.draw(single, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        ctx.draw(image, in: bounds)
        ctx.setFillColor(
            CGColor(
                srgbRed: CGFloat(px[0]) / 255.0,
                green: CGFloat(px[1]) / 255.0,
                blue: CGFloat(px[2]) / 255.0,
                alpha: 1.0
            )
        )
        let cgRect = CGRect(
            x: target.minX,
            y: CGFloat(h) - target.maxY,
            width: target.width,
            height: target.height
        )
        ctx.fill(cgRect)
        return ctx.makeImage() ?? image
    }

    /// Reconstructs `ShareX.ImageEditor` `MagnifyAnnotation` (2× circular/elliptical zoom loupe with crisp ring).
    private static func applyMagnifyLoupe(to image: CGImage, item: AnnotationItem) -> CGImage {
        let w = image.width
        let h = image.height
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let target = item.boundingRect.intersection(bounds).integral
        guard target.width >= 12, target.height >= 12 else { return image }

        let zoom: CGFloat = 2.0
        let srcW = max(4, target.width / zoom)
        let srcH = max(4, target.height / zoom)
        let srcRectTopLeft = CGRect(
            x: target.midX - srcW * 0.5,
            y: target.midY - srcH * 0.5,
            width: srcW,
            height: srcH
        ).intersection(bounds)

        guard let cropped = image.cropping(to: srcRectTopLeft),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }

        ctx.draw(image, in: bounds)
        let destCG = CGRect(
            x: target.minX,
            y: CGFloat(h) - target.maxY,
            width: target.width,
            height: target.height
        )

        ctx.saveGState()
        ctx.addEllipse(in: destCG)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: destCG)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(gray: 0, alpha: 0.4))
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setLineWidth(max(2.5, item.strokeWidth))
        ctx.strokeEllipse(in: destCG)
        ctx.restoreGState()

        return ctx.makeImage() ?? image
    }

    /// Reconstructs `ShareX.ImageEditor` `SpeechBalloonAnnotation` (rounded callout bubble + pointer tail + centered text).
    private static func drawSpeechBalloon(item: AnnotationItem, rect: CGRect, in ctx: CGContext) {
        let tailHeight = min(18.0, rect.height * 0.25)
        let bodyRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: max(16.0, rect.height - tailHeight)
        )
        let path = CGMutablePath()
        path.addRoundedRect(in: bodyRect, cornerWidth: 10, cornerHeight: 10)
        path.move(to: CGPoint(x: bodyRect.minX + bodyRect.width * 0.22, y: bodyRect.maxY - 1))
        path.addLine(to: CGPoint(x: bodyRect.minX + bodyRect.width * 0.16, y: rect.maxY))
        path.addLine(to: CGPoint(x: bodyRect.minX + bodyRect.width * 0.36, y: bodyRect.maxY - 1))
        path.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path)
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setLineWidth(max(2.0, item.strokeWidth * 0.75))
        ctx.strokePath()
        ctx.restoreGState()

        let content = item.text.isEmpty ? "Callout" : item.text
        drawTopLeftText(
            content,
            center: CGPoint(x: bodyRect.midX, y: bodyRect.midY),
            fontSize: max(13, min(item.fontSize, bodyRect.height * 0.48)),
            bold: true,
            color: .black,
            in: ctx
        )
    }
}
