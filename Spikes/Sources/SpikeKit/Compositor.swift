import AVFoundation
import CoreText
import Metal
import Synchronization
import simd

// MARK: - Render graph (spike version of ClipperCore's Item/Param)

/// A keyframed scalar. Keyframe times are relative to the instruction start, eased with smoothstep.
public struct Track1D: Sendable {
    public var keys: [(t: Double, v: Double)]
    public init(_ constant: Double) { keys = [(0, constant)] }
    public init(_ keys: [(Double, Double)]) { self.keys = keys.map { (t: $0.0, v: $0.1) } }

    public func value(at t: Double) -> Double {
        guard let first = keys.first else { return 0 }
        if t <= first.t { return first.v }
        for (a, b) in zip(keys, keys.dropFirst()) where t <= b.t {
            let u = (t - a.t) / max(b.t - a.t, 1e-9)
            let s = u * u * (3 - 2 * u)
            return a.v + (b.v - a.v) * s
        }
        return keys.last!.v
    }
}

public enum Fit: Sendable { case fill, fit, width(Double) }

/// How the compositor decodes source pixels. `.appleConverted` means AVFoundation already tone-mapped to SDR.
public enum SourceTransfer: Int32, Sendable { case sdr = 0, hlg = 1, pq = 2 }

public struct CaptionWord: Sendable { public var text: String; public var start, end: Double
    public init(_ text: String, _ start: Double, _ end: Double) { self.text = text; self.start = start; self.end = end } }

public enum LayerSource: Sendable {
    case track(CMPersistentTrackID, transfer: SourceTransfer = .sdr)
    case text(String, size: CGFloat)
    /// Word-by-word caption: the active word is highlighted (one cached texture per word state).
    case caption([CaptionWord], size: CGFloat)
    case solid(SIMD4<Float>)
}

public struct Layer: Sendable {
    public var source: LayerSource
    public var fit: Fit
    public var centerX, centerY, scale, rotation, opacity: Track1D
    public init(_ source: LayerSource, fit: Fit = .fit,
                centerX: Track1D = .init(0.5), centerY: Track1D = .init(0.5), scale: Track1D = .init(1),
                rotation: Track1D = .init(0), opacity: Track1D = .init(1)) {
        self.source = source; self.fit = fit; self.centerX = centerX; self.centerY = centerY
        self.scale = scale; self.rotation = rotation; self.opacity = opacity
    }
}

public final class SpikeInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    public let layers: [Layer]

    public init(timeRange: CMTimeRange, layers: [Layer]) {
        self.timeRange = timeRange
        self.layers = layers
        let ids = layers.compactMap { l -> CMPersistentTrackID? in if case .track(let id, _) = l.source { id } else { nil } }
        requiredSourceTrackIDs = ids.map { NSNumber(value: $0) }
    }
}

// MARK: - Compositor

/// Spike compositor. SDR variant: AVFoundation hands us BGRA already converted to Rec.709
/// (including Apple's own HDR→SDR conversion). HDR variant: we receive half-float frames still in
/// HLG or PQ and tone-map them ourselves in the shader.
public class SpikeCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    public class var wantsHDR: Bool { false }

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.wantsHDR ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    public var supportsHDRSourceFrames: Bool { Self.wantsHDR }
    public var supportsWideColorSourceFrames: Bool { Self.wantsHDR }

    private let gpu = GPU.shared
    private let renderQueue = DispatchQueue(label: "spike.compositor", qos: .userInteractive)
    private let renderSize = Mutex(CGSize.zero)

    /// Log the colour tags of the first source frame we see (used by S2).
    nonisolated(unsafe) public static var logFirstSource = false

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderSize.withLock { $0 = newRenderContext.size }
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let req = Unchecked(request)
        renderQueue.async { [self] in
            do { try render(req.value) } catch { req.value.finish(with: error) }
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {}

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws {
        guard let instr = request.videoCompositionInstruction as? SpikeInstruction,
              let outBuf = request.renderContext.newPixelBuffer() else { throw CocoaError(.coderInvalidValue) }
        let canvas = SIMD2<Float>(Float(CVPixelBufferGetWidth(outBuf)), Float(CVPixelBufferGetHeight(outBuf)))
        let t = (request.compositionTime - instr.timeRange.start).seconds
        let outTex = try gpu.texture(outBuf, format: .bgra8Unorm)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = outTex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = gpu.queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { throw CocoaError(.coderInvalidValue) }
        enc.setRenderPipelineState(gpu.pipeline)
        var keepAlive: [Any] = [outBuf]

        for layer in instr.layers {
            let opacity = Float(layer.opacity.value(at: t))
            guard opacity > 0.001 else { continue }
            var texture: MTLTexture
            var transfer = SourceTransfer.sdr
            var tint = SIMD4<Float>(1, 1, 1, 1)
            switch layer.source {
            case .track(let id, let tf):
                guard let src = request.sourceFrame(byTrackID: id) else { continue }
                if Self.logFirstSource { Self.logFirstSource = false; print("  source frame: \(Pixels.describeColor(src))") }
                texture = try gpu.texture(src, format: Self.wantsHDR ? .rgba16Float : .bgra8Unorm)
                transfer = Self.wantsHDR ? tf : .sdr
                keepAlive.append(src)
            case .text(let string, let size):
                texture = try gpu.textTexture(string, size: size, highlight: nil)
            case .caption(let words, let size):
                guard let first = words.first, let last = words.last, t >= first.start, t <= last.end + 0.3 else { continue }
                let active = words.lastIndex { t >= $0.start } ?? 0
                texture = try gpu.textTexture(words.map(\.text).joined(separator: " "), size: size, highlight: active)
            case .solid(let c):
                texture = gpu.white; tint = c
            }

            // Base size in canvas pixels from the fit mode, preserving the source aspect.
            let srcSize = SIMD2<Float>(Float(texture.width), Float(texture.height))
            var base: SIMD2<Float>
            switch (layer.source, layer.fit) {
            case (.text, _), (.caption, _): base = srcSize
            case (.solid, _): base = canvas
            case (_, .fill): base = srcSize * max(canvas.x / srcSize.x, canvas.y / srcSize.y)
            case (_, .fit): base = srcSize * min(canvas.x / srcSize.x, canvas.y / srcSize.y)
            case (_, .width(let f)): base = srcSize * (Float(f) * canvas.x / srcSize.x)
            }
            let size = base * Float(layer.scale.value(at: t))
            let center = SIMD2<Float>(Float(layer.centerX.value(at: t)), Float(layer.centerY.value(at: t))) * canvas
            let theta = Float(layer.rotation.value(at: t))

            // Unit quad (-0.5…0.5) → pixels → NDC, as one affine matrix.
            let quadToPx = simd_float3x3(columns: (
                SIMD3(cos(theta) * size.x, sin(theta) * size.x, 0),
                SIMD3(-sin(theta) * size.y, cos(theta) * size.y, 0),
                SIMD3(center.x, center.y, 1)))
            let pxToNdc = simd_float3x3(columns: (
                SIMD3(2 / canvas.x, 0, 0), SIMD3(0, -2 / canvas.y, 0), SIMD3(-1, 1, 1)))
            var u = LayerUniforms(transform: pxToNdc * quadToPx, tint: tint * opacity, transfer: transfer.rawValue)
            enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        if Self.wantsHDR {   // we tone-mapped to SDR ourselves: tag the result so nothing downstream converts again
            CVBufferSetAttachment(outBuf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(outBuf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(outBuf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        let req = Unchecked(request), out = Unchecked(outBuf), alive = Unchecked(keepAlive)
        cmd.addCompletedHandler { _ in
            _ = alive
            req.value.finish(withComposedVideoFrame: out.value)
        }
        cmd.commit()
    }
}

/// HDR variant: receives untouched HLG/PQ half-float frames and tone-maps them in the shader.
public final class SpikeHDRCompositor: SpikeCompositor, @unchecked Sendable {
    override public class var wantsHDR: Bool { true }
}

struct LayerUniforms {
    var transform: simd_float3x3
    var tint: SIMD4<Float>
    var transfer: Int32
}

// MARK: - GPU resources

final class GPU: @unchecked Sendable {
    static let shared = GPU()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let white: MTLTexture
    private let cache: CVMetalTextureCache
    private let textLock = NSLock()
    private var textCache: [String: MTLTexture] = [:]

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        // No Xcode `metal` compiler with only Command Line Tools installed, so compile at runtime.
        let lib = try! device.makeLibrary(source: shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "layer_vertex")
        desc.fragmentFunction = lib.makeFunction(name: "layer_fragment")
        let ca = desc.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
        cache = c!
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        white = device.makeTexture(descriptor: td)!
        var px: [UInt8] = [255, 255, 255, 255]
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
    }

    func texture(_ buf: CVPixelBuffer, format: MTLPixelFormat) throws -> MTLTexture {
        var tex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buf, nil, format,
                                                                CVPixelBufferGetWidth(buf), CVPixelBufferGetHeight(buf), 0, &tex)
        guard status == kCVReturnSuccess, let tex, let mtl = CVMetalTextureGetTexture(tex) else {
            throw CocoaError(.coderInvalidValue, userInfo: [NSDebugDescriptionErrorKey: "CVMetalTexture \(status)"])
        }
        return mtl
    }

    /// Core Text → premultiplied BGRA texture, cached by (string, size, highlighted word).
    func textTexture(_ string: String, size: CGFloat, highlight: Int?) throws -> MTLTexture {
        let key = "\(size)|\(highlight ?? -1)|\(string)"
        if let hit = textLock.withLock({ textCache[key] }) { return hit }

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attr = NSMutableAttributedString(string: string, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            .init(kCTStrokeWidthAttributeName as String): -3.0,
            .init(kCTStrokeColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        if let highlight {
            var loc = 0
            for (i, word) in string.split(separator: " ").enumerated() {
                if i == highlight {
                    attr.addAttribute(.init(kCTForegroundColorAttributeName as String),
                                      value: CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1),
                                      range: NSRange(location: loc, length: word.utf16.count))
                }
                loc += word.utf16.count + 1
            }
        }
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let pad: CGFloat = size * 0.2
        let w = Int(ceil(width + pad * 2)), h = Int(ceil(ascent + descent + pad * 2))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(line, ctx)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        guard let tex = device.makeTexture(descriptor: td), let data = ctx.data else { throw CocoaError(.coderInvalidValue) }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        textLock.withLock { textCache[key] = tex }
        return tex
    }
}

// Rec.2020 HLG/PQ → linear → Rec.709 primaries → fitted luminance tone curve → BT.709 OETF.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float3x3 transform; float4 tint; int transfer; };
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut layer_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    float2 corners[4] = { float2(-0.5,-0.5), float2(0.5,-0.5), float2(-0.5,0.5), float2(0.5,0.5) };
    float2 c = corners[vid];
    float3 p = u.transform * float3(c, 1.0);
    VOut o; o.pos = float4(p.xy, 0, 1); o.uv = c + 0.5; return o;
}

static float hlg_inv_oetf(float e) {
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    return e <= 0.5 ? (e * e) / 3.0 : (exp((e - c) / a) + b) / 12.0;
}
static float pq_eotf(float e) {   // → nits / 10000
    const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float p = pow(max(e, 0.0), 1.0 / m2);
    return pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
}
// Luminance-based curves fitted (S2) to AVFoundation's own SDR conversion of a signal ramp:
//   HLG: Y_sdr = Y_scene^0.654                         (RMSE ≈ 2/255 vs Apple)
//   PQ : x = nits/180, Y_sdr = (x(1 + x/1.5²)/(1 + x))^0.7  (RMSE ≈ 3/255 vs Apple)
// Applied to luminance and scaled back onto RGB so saturated colours keep their hue.
static float3 apply_luma_curve(float3 rgb, float y_out) {
    float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    return y > 1e-6 ? rgb * (y_out / y) : float3(0.0);
}
static float3 bt709_oetf(float3 l) {
    l = clamp(l, 0.0, 1.0);
    return select(4.5 * l, 1.099 * pow(l, 0.45) - 0.099, l >= 0.018);
}

fragment float4 layer_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant Uniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(s, in.uv);
    if (u.transfer != 0) {
        const float3x3 bt2020_to_709 = float3x3(float3(1.6605, -0.1246, -0.0182),
                                                float3(-0.5876, 1.1329, -0.1006),
                                                float3(-0.0728, -0.0083, 1.1187));
        float3 sdr;
        if (u.transfer == 1) {   // HLG: scene-linear → SDR
            float3 sc = max(bt2020_to_709 * float3(hlg_inv_oetf(c.r), hlg_inv_oetf(c.g), hlg_inv_oetf(c.b)), 0.0);
            float y = dot(sc, float3(0.2126, 0.7152, 0.0722));
            sdr = apply_luma_curve(sc, pow(max(y, 0.0), 0.654));
        } else {                 // PQ: absolute nits → SDR
            float3 n = max(bt2020_to_709 * (float3(pq_eotf(c.r), pq_eotf(c.g), pq_eotf(c.b)) * 10000.0), 0.0);
            float x = dot(n, float3(0.2126, 0.7152, 0.0722)) / 180.0;
            float y_out = pow(x * (1.0 + x / 2.25) / (1.0 + x), 0.7);
            sdr = apply_luma_curve(n / 180.0, y_out);
        }
        c = float4(bt709_oetf(sdr), 1.0);
    }
    return c * u.tint;   // tint already includes opacity; textures are premultiplied
}
"""
