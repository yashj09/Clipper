import AVFoundation
import ClipperCore
import Metal
import simd

/// The one compositor used for both preview (AVPlayer) and export (AVAssetReader), so they match exactly (ADR 0003).
///
/// Sources arrive in their native colour space (`canConformColorOfSourceFrames`): SDR stays Rec.709 and iPhone
/// footage stays BT.2020 HLG, and every layer is converted in our shader (ADR 0006).
public final class ClipperCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    public var supportsWideColorSourceFrames: Bool { true }
    public var supportsHDRSourceFrames: Bool { true }
    public var canConformColorOfSourceFrames: Bool { true }

    private let gpu = GPU.shared
    private let queue = DispatchQueue(label: "clipper.compositor", qos: .userInteractive)

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let req = UncheckedSendable(request)
        queue.async { [self] in
            do { try render(req.value) } catch { req.value.finish(with: error) }
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {}

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws {
        guard let instruction = request.videoCompositionInstruction as? RenderInstruction,
              let output = request.renderContext.newPixelBuffer(),
              let (target, targetOwner) = gpu.texture(for: output, format: .bgra8Unorm) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "compositor setup failed"])
        }
        let ctx = instruction.context
        let outSize = SIMD2(Double(CVPixelBufferGetWidth(output)), Double(CVPixelBufferGetHeight(output)))
        // Preview may render below canvas resolution, and a preset of another shape letterboxes the canvas; layers are
        // laid out in the canvas frame and text (rasterized at canvas size) is scaled by its scale.
        let canvasFrame = CanvasFrame.fitting(canvas: SIMD2(Double(ctx.canvas.width), Double(ctx.canvas.height)), in: outSize)
        let canvasSize = canvasFrame.size
        let renderScale = canvasFrame.scale
        let now = RationalTime(request.compositionTime)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        let bg = ctx.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: bg.r * bg.a, green: bg.g * bg.a, blue: bg.b * bg.a, alpha: bg.a)
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = gpu.queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            throw CocoaError(.featureUnsupported)
        }
        enc.setRenderPipelineState(gpu.pipeline)
        if canvasFrame.isLetterboxed {
            // Keep layers that extend past the canvas edge out of the bars, as the preview clips them at the canvas.
            enc.setScissorRect(MTLScissorRect(x: Int(canvasFrame.origin.x), y: Int(canvasFrame.origin.y),
                                              width: min(Int(canvasSize.x.rounded()), Int(outSize.x) - Int(canvasFrame.origin.x)),
                                              height: min(Int(canvasSize.y.rounded()), Int(outSize.y) - Int(canvasFrame.origin.y))))
        }
        var retained: [AnyObject] = [output, targetOwner]

        for layer in instruction.layers {
            let local = now - layer.start
            var opacity = layer.effectiveOpacity(at: local)
            guard opacity > 0.001 else { continue }
            var tint = SIMD4<Float>(1, 1, 1, 1)
            var transfer: Int32 = 0
            let texture: MTLTexture
            let geometry: LayerGeometry
            var orientation = Orientation.identity

            switch layer.source {
            case .media(let trackID, let displaySize, let orient, let tf):
                guard let frame = request.sourceFrame(byTrackID: trackID),
                      let (tex, owner) = gpu.texture(for: frame, format: .rgba16Float) else { continue }
                texture = tex
                retained.append(frame)
                retained.append(owner)
                transfer = Self.transferCode(of: frame, fallback: tf)
                orientation = orient
                geometry = .media(transform: layer.transform, at: local, canvas: canvasSize, sourceSize: displaySize)
            case .image(let url, let displaySize):
                guard let tex = gpu.imageTexture(url) else { continue }
                texture = tex
                geometry = .media(transform: layer.transform, at: local, canvas: canvasSize, sourceSize: displaySize)
            case .solid(let color):
                texture = gpu.white
                tint = SIMD4(Float(color.r * color.a), Float(color.g * color.a), Float(color.b * color.a), Float(color.a))
                geometry = .media(transform: layer.transform, at: local, canvas: canvasSize, sourceSize: canvasSize)
            case .text(let content):
                guard let style = ctx.styles[content.style] else { continue }
                let words = content.text.split(separator: " ").map(String.init)
                let key = GPU.TextKey(words: words, emphasis: [], style: content.style, styleHash: ctx.styleHashes[content.style] ?? 0,
                                      canvas: SIMD2(ctx.canvas.width, ctx.canvas.height), options: .init())
                guard let tex = gpu.textTexture(key, style: style) else { continue }
                texture = tex
                geometry = .text(transform: layer.transform, at: local, canvas: canvasSize,
                                 textureSize: SIMD2(Double(tex.width), Double(tex.height)), extraScale: renderScale)
            case .caption(let caption):
                guard let style = ctx.styles[caption.style] else { continue }
                let state = CaptionState(caption: caption, style: style, at: local)
                guard state.visible else { continue }
                opacity *= state.opacity
                let key = GPU.TextKey(words: caption.words.map(\.text), emphasis: caption.words.map(\.emphasis), style: caption.style,
                                      styleHash: ctx.styleHashes[caption.style] ?? 0, canvas: SIMD2(ctx.canvas.width, ctx.canvas.height),
                                      options: .init(activeWord: style.highlight == nil ? nil : state.active,
                                                     revealUpTo: style.animation == .wordByWord ? state.active : nil))
                guard let tex = gpu.textTexture(key, style: style) else { continue }
                texture = tex
                geometry = .text(transform: layer.transform, at: local, canvas: canvasSize,
                                 textureSize: SIMD2(Double(tex.width), Double(tex.height)), extraScale: renderScale * state.scale)
            }

            var uniforms = LayerUniforms()
            let ndc = geometry.corners.map { $0 + canvasFrame.origin }
                .map { SIMD2<Float>(Float($0.x / outSize.x * 2 - 1), Float(1 - $0.y / outSize.y * 2)) }
            let r = geometry.sourceRect
            let display: [SIMD2<Double>] = [SIMD2(r.x, r.y), SIMD2(r.x + r.width, r.y), SIMD2(r.x, r.y + r.height),
                                            SIMD2(r.x + r.width, r.y + r.height)]
            let uv = display.map { orientation.textureCoordinate($0) }.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
            uniforms.position = (ndc[0], ndc[1], ndc[2], ndc[3])
            uniforms.texcoord = (uv[0], uv[1], uv[2], uv[3])
            uniforms.tint = tint * Float(opacity)
            uniforms.transfer = transfer
            enc.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()

        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        let req = UncheckedSendable(request), out = UncheckedSendable(output), keep = UncheckedSendable(retained)
        let gpu = self.gpu
        cmd.addCompletedHandler { _ in
            _ = keep
            req.value.finish(withComposedVideoFrame: out.value)
            gpu.flushTextureCache()
        }
        cmd.commit()
    }

    /// The buffer's own colour tags are authoritative; fall back to what probing found.
    static func transferCode(of buffer: CVPixelBuffer, fallback: TransferFunction) -> Int32 {
        if let tf = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String {
            if tf == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) { return 1 }
            if tf == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) { return 2 }
            return 0
        }
        switch fallback { case .sdr: return 0; case .hlg: return 1; case .pq: return 2 }
    }
}

/// Per-frame caption state: which word is active and the page's entrance animation.
struct CaptionState {
    var active: Int
    var visible: Bool
    var scale: Double
    var opacity: Double

    init(caption: CaptionContent, style: TextStyle, at t: RationalTime) {
        let words = caption.words
        active = max(0, (words.lastIndex { $0.start <= t }) ?? 0)
        visible = !words.isEmpty
        let s = t.seconds
        switch style.animation {
        case .pop:
            let u = min(max(s / 0.12, 0), 1)
            scale = 0.85 + 0.15 * (1 - (1 - u) * (1 - u))
            opacity = 1
        case .fade:
            scale = 1; opacity = min(max(s / 0.15, 0), 1)
        case .wordByWord, .none:
            scale = 1; opacity = 1
        }
    }
}

struct LayerUniforms {
    var position: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) = (.zero, .zero, .zero, .zero)
    var texcoord: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) = (.zero, .zero, .zero, .zero)
    var tint = SIMD4<Float>(1, 1, 1, 1)
    var transfer: Int32 = 0
}
