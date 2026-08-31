import CoreGraphics
import CoreText
import Foundation
import ImageIO
import JavaScriptCore

/// Native rendering for the explicitly supported artifact preview surface.
/// Images must already be in the sandbox; rendering never performs network I/O.
func installArtifactPreviewBridge(into context: JSContext) {
    let render: @convention(block) (String) -> String? = { json in
        do {
            return try renderArtifactPreview(json).base64EncodedString()
        } catch {
            context.exception = JSValue(newErrorFromMessage: "artifact preview: \(error.localizedDescription)", in: context)
            return nil
        }
    }
    context.setObject(render, forKeyedSubscript: "__jb_render_artifact" as NSString)
}

private enum ArtifactPreviewError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

private func renderArtifactPreview(_ json: String) throws -> Data {
    guard let data = json.data(using: .utf8),
          let scene = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ArtifactPreviewError.invalid("Invalid scene")
    }
    let width = Int(number(scene["width"], 1280)), height = Int(number(scene["height"], 720))
    guard width > 0, height > 0, width <= 1800, height <= 1800,
          let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw ArtifactPreviewError.invalid("Preview must be between 1 and 1800 pixels per axis")
    }
    cg.setFillColor(previewColor(scene["background"], fallback: [1, 1, 1, 1]))
    cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for element in scene["elements"] as? [[String: Any]] ?? [] {
        let box = element["frame"] as? [String: Any] ?? [:]
        let rect = CGRect(x: number(box["left"]), y: CGFloat(height) - number(box["top"]) - number(box["height"]),
                          width: number(box["width"]), height: number(box["height"]))
        guard rect.width >= 0, rect.height >= 0 else { throw ArtifactPreviewError.invalid("Negative frame size") }
        if let encoded = element["imageBase64"] as? String {
            guard let bytes = Data(base64Encoded: encoded),
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ArtifactPreviewError.invalid("Image preview requires a decodable PNG or JPEG; SVG preview is unsupported")
            }
            cg.draw(image, in: rect)
            continue
        }
        let ellipse = element["geometry"] as? String == "ellipse"
        if element["fill"] != nil && !(element["fill"] is NSNull) {
            cg.setFillColor(previewColor(element["fill"]))
            if ellipse { cg.fillEllipse(in: rect) } else { cg.fill(rect) }
        }
        let lineWidth = number(element["lineWidth"])
        if lineWidth > 0 {
            cg.setLineWidth(lineWidth)
            cg.setStrokeColor(previewColor(element["lineColor"]))
            if ellipse { cg.strokeEllipse(in: rect) } else { cg.stroke(rect) }
        }
        if let text = element["text"] as? String, !text.isEmpty {
            var font = CTFontCreateWithName((element["typeface"] as? String ?? "Helvetica") as CFString,
                                          number(element["fontSize"], 16), nil)
            var traits: CTFontSymbolicTraits = []
            if element["bold"] as? Bool == true { traits.insert(.boldTrait) }
            if element["italic"] as? Bool == true { traits.insert(.italicTrait) }
            if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) { font = styled }
            var alignment: CTTextAlignment = switch element["alignment"] as? String {
            case "center": .center
            case "right": .right
            case "justify": .justified
            default: .left
            }
            let paragraph = withUnsafePointer(to: &alignment) { pointer in
                var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
                return CTParagraphStyleCreate(&setting, 1)
            }
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): previewColor(element["color"]),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ])
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let inset = number(element["inset"], 4)
            let textRect = rect.insetBy(dx: inset, dy: inset)
            guard textRect.width > 0, textRect.height > 0 else { continue }
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            cg.saveGState()
            cg.textMatrix = .identity
            CTFrameDraw(frame, cg)
            cg.restoreGState()
        }
    }
    guard let image = cg.makeImage() else { throw ArtifactPreviewError.invalid("Could not create preview") }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
        throw ArtifactPreviewError.invalid("PNG encoder unavailable")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ArtifactPreviewError.invalid("PNG encoding failed") }
    return output as Data
}

private func number(_ value: Any?, _ fallback: CGFloat = 0) -> CGFloat {
    guard let number = value as? NSNumber, number.doubleValue.isFinite else { return fallback }
    return CGFloat(number.doubleValue)
}

private func previewColor(_ value: Any?, fallback: [CGFloat] = [0, 0, 0, 1]) -> CGColor {
    if let components = value as? [NSNumber], components.count >= 3 {
        return CGColor(red: CGFloat(components[0].doubleValue) / 255, green: CGFloat(components[1].doubleValue) / 255,
                       blue: CGFloat(components[2].doubleValue) / 255,
                       alpha: components.count > 3 ? CGFloat(components[3].doubleValue) / 255 : 1)
    }
    return CGColor(red: fallback[0], green: fallback[1], blue: fallback[2], alpha: fallback[3])
}
