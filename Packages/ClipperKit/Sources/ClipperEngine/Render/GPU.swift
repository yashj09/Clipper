import ClipperCore
import CoreVideo
import Foundation
import ImageIO
import Metal

/// Shared Metal state: device, pipeline, texture caches. Thread-safe; used by every compositor instance.
final class GPU: @unchecked Sendable {
    static let shared = GPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let white: MTLTexture
    private let textureCache: CVMetalTextureCache
    private let lock = NSLock()
    private var textCache: [TextKey: MTLTexture] = [:]
    private var textOrder: [TextKey] = []
    private var imageCache: [URL: MTLTexture] = [:]
    static let textCacheLimit = 512

    struct TextKey: Hashable {
        var words: [String]
        var emphasis: [Bool]
        var style: String
        var styleHash: Int
        var canvas: SIMD2<Int>
        var options: TextRenderer.Options
    }

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        // Shaders are compiled from source at startup (≈ tens of ms): works identically under `swift build` and Xcode.
        let library = try! device.makeLibrary(source: Shaders.source, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "layer_vertex")
        desc.fragmentFunction = library.makeFunction(name: "layer_fragment")
        let ca = desc.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache!
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        white = device.makeTexture(descriptor: td)!
        var px: [UInt8] = [255, 255, 255, 255]
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
    }

    func texture(for buffer: CVPixelBuffer, format: MTLPixelFormat) -> MTLTexture? {
        var tex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format,
                                                                CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &tex)
        guard status == kCVReturnSuccess, let tex else { return nil }
        return CVMetalTextureGetTexture(tex)
    }

    func makeTexture(_ image: CGImage) -> MTLTexture? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = { ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.data }()
        else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return tex
    }

    func textTexture(_ key: TextKey, style: TextStyle) -> MTLTexture? {
        if let hit = lock.withLock({ textCache[key] }) { return hit }
        guard let image = TextRenderer.render(words: key.words, emphasis: key.emphasis, style: style,
                                              canvasWidth: key.canvas.x, canvasHeight: key.canvas.y, options: key.options),
              let tex = makeTexture(image) else { return nil }
        lock.withLock {
            textCache[key] = tex
            textOrder.append(key)
            if textOrder.count > Self.textCacheLimit { textCache[textOrder.removeFirst()] = nil }
        }
        return tex
    }

    /// Still images, decoded upright (EXIF applied) and capped at 4096 px.
    func imageTexture(_ url: URL) -> MTLTexture? {
        if let hit = lock.withLock({ imageCache[url] }) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary),
              let tex = makeTexture(image) else { return nil }
        lock.withLock { imageCache[url] = tex }
        return tex
    }
}

enum Shaders {
    /// Per-layer draw. Sources are either half-float RGBA in their native transfer (SDR Rec.709 gamma, HLG, PQ)
    /// or premultiplied BGRA (text, images, solids). HDR is tone-mapped to SDR here (ADR 0006).
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct LayerUniforms {
        float2 position[4];     // NDC corners: TL, TR, BL, BR
        float2 texcoord[4];
        float4 tint;            // premultiplied colour × opacity
        int transfer;           // 0 SDR, 1 HLG, 2 PQ
    };
    struct VOut { float4 pos [[position]]; float2 uv; };

    vertex VOut layer_vertex(uint vid [[vertex_id]], constant LayerUniforms &u [[buffer(0)]]) {
        VOut o; o.pos = float4(u.position[vid], 0, 1); o.uv = u.texcoord[vid]; return o;
    }

    static float hlg_inv_oetf(float e) {
        const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
        return e <= 0.5 ? (e * e) / 3.0 : (exp((e - c) / a) + b) / 12.0;
    }
    static float pq_eotf(float e) {
        const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
        float p = pow(max(e, 0.0), 1.0 / m2);
        return pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
    }
    static float3 bt709_oetf(float3 l) {
        l = clamp(l, 0.0, 1.0);
        return select(4.5 * l, 1.099 * pow(l, 0.45) - 0.099, l >= 0.018);
    }
    static float3 apply_luma(float3 rgb, float y_out) {
        float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        return y > 1e-6 ? rgb * (y_out / y) : float3(0.0);
    }

    fragment float4 layer_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                   constant LayerUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        if (u.transfer != 0) {
            const float3x3 bt2020_to_709 = float3x3(float3(1.6605, -0.1246, -0.0182),
                                                    float3(-0.5876, 1.1329, -0.1006),
                                                    float3(-0.0728, -0.0083, 1.1187));
            float3 sdr;
            if (u.transfer == 1) {
                float3 sc = max(bt2020_to_709 * float3(hlg_inv_oetf(c.r), hlg_inv_oetf(c.g), hlg_inv_oetf(c.b)), 0.0);
                float y = dot(sc, float3(0.2126, 0.7152, 0.0722));
                sdr = apply_luma(sc, pow(max(y, 0.0), 0.654));
            } else {
                float3 n = max(bt2020_to_709 * (float3(pq_eotf(c.r), pq_eotf(c.g), pq_eotf(c.b)) * 10000.0), 0.0);
                float x = dot(n, float3(0.2126, 0.7152, 0.0722)) / 180.0;
                sdr = apply_luma(n / 180.0, pow(x * (1.0 + x / 2.25) / (1.0 + x), 0.7));
            }
            c = float4(bt709_oetf(sdr), 1.0);
        }
        return c * u.tint;
    }
    """
}
