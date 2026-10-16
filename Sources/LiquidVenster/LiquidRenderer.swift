import CoreGraphics
import Foundation
import Metal
import simd

enum RenderError: Error, LocalizedError {
    case noDevice
    case noCommandQueue
    case shaderCompile(String)
    case pipeline(String)
    case texture(String)
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "No Metal GPU available"
        case .noCommandQueue: return "Could not create a Metal command queue"
        case .shaderCompile(let m): return "Shader compilation failed: \(m)"
        case .pipeline(let m): return "Render pipeline failed: \(m)"
        case .texture(let m): return "Texture error: \(m)"
        case .encoding(let m): return "Render error: \(m)"
        }
    }
}

/// CPU copy of an image (premultiplied BGRA, top row first), used to sample alpha.
struct PixelData {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    /// Alpha (0...1) at normalized coordinates, nearest sample, clamped to the edges.
    func alpha(u: Float, v: Float) -> Float {
        guard width > 0, height > 0, u.isFinite, v.isFinite else { return 0 }
        let x = min(max(Int(u * Float(width)), 0), width - 1)
        let y = min(max(Int(v * Float(height)), 0), height - 1)
        let index = y * bytesPerRow + x * 4 + 3   // BGRA little-endian premultiplied-first -> A is byte 3
        guard index >= 0, index < bytes.count else { return 0 }
        return Float(bytes[index]) / 255
    }

    /// Fraction of pixels (sampled on a grid) that are at least partly opaque.
    func coverage(samples: Int = 48) -> Float {
        var hits = 0
        for j in 0..<samples {
            for i in 0..<samples where alpha(u: (Float(i) + 0.5) / Float(samples), v: (Float(j) + 0.5) / Float(samples)) > 0.1 {
                hits += 1
            }
        }
        return Float(hits) / Float(samples * samples)
    }
}

/// Shared Metal objects (device, pipelines). Created once; compiling the shaders
/// takes ~100 ms so the app warms this up at launch.
final class LiquidRenderer {
    private static let lock = NSLock()
    private static var cached: Result<LiquidRenderer, Error>?

    /// Returns the shared renderer or the (cached) error that prevented creating it.
    static func shared() -> Result<LiquidRenderer, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let result: Result<LiquidRenderer, Error>
        do {
            result = .success(try LiquidRenderer())
            logInfo("Metal renderer ready")
        } catch {
            result = .failure(error)
            logError("Metal renderer could not start: \(error.liquidDescription)")
        }
        cached = result
        return result
    }

    static let fluidFormat: MTLPixelFormat = .rgba16Float
    static let outputFormat: MTLPixelFormat = .bgra8Unorm
    /// Larger images are scaled down before upload (well within every GPU's limit).
    static let maxTextureDimension = 8192

    let device: MTLDevice
    let queue: MTLCommandQueue
    let splatPipeline: MTLRenderPipelineState
    let compositePipeline: MTLRenderPipelineState
    let zeroSampler: MTLSamplerState
    let edgeSampler: MTLSamplerState
    let emptyTexture: MTLTexture

    init(device candidate: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device = candidate else { throw RenderError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RenderError.noCommandQueue }
        queue.label = "LiquidVenster"
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: LiquidShaders.source, options: MTLCompileOptions())
        } catch {
            throw RenderError.shaderCompile(error.localizedDescription)
        }
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else {
                throw RenderError.shaderCompile("function '\(name)' missing")
            }
            return f
        }

        let splat = MTLRenderPipelineDescriptor()
        splat.label = "splat"
        splat.vertexFunction = try function("splatVertex")
        splat.fragmentFunction = try function("splatFragment")
        guard let splatColor = splat.colorAttachments[0] else { throw RenderError.pipeline("no color attachment") }
        splatColor.pixelFormat = LiquidRenderer.fluidFormat
        splatColor.isBlendingEnabled = true
        splatColor.rgbBlendOperation = .add
        splatColor.alphaBlendOperation = .add
        splatColor.sourceRGBBlendFactor = .one
        splatColor.destinationRGBBlendFactor = .one
        splatColor.sourceAlphaBlendFactor = .one
        splatColor.destinationAlphaBlendFactor = .one

        let composite = MTLRenderPipelineDescriptor()
        composite.label = "composite"
        composite.vertexFunction = try function("fullscreenVertex")
        composite.fragmentFunction = try function("compositeFragment")
        guard let compositeColor = composite.colorAttachments[0] else { throw RenderError.pipeline("no color attachment") }
        compositeColor.pixelFormat = LiquidRenderer.outputFormat
        compositeColor.isBlendingEnabled = false

        do {
            splatPipeline = try device.makeRenderPipelineState(descriptor: splat)
            compositePipeline = try device.makeRenderPipelineState(descriptor: composite)
        } catch {
            throw RenderError.pipeline(error.localizedDescription)
        }

        func sampler(_ mode: MTLSamplerAddressMode) throws -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = .linear
            d.magFilter = .linear
            d.sAddressMode = mode
            d.tAddressMode = mode
            d.normalizedCoordinates = true
            guard let s = device.makeSamplerState(descriptor: d) else { throw RenderError.pipeline("sampler") }
            return s
        }
        zeroSampler = try sampler(.clampToZero)
        edgeSampler = try sampler(.clampToEdge)

        let emptyDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        emptyDesc.usage = .shaderRead
        emptyDesc.storageMode = .managed
        guard let empty = device.makeTexture(descriptor: emptyDesc) else { throw RenderError.texture("empty texture") }
        var zero: UInt32 = 0
        empty.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        emptyTexture = empty
    }

    /// Draws `image` into a premultiplied BGRA buffer in `colorSpace` (top row first) and uploads it.
    /// Optionally applies a rounded-corner mask (used for snapshots of our own windows).
    func makeTexture(from image: CGImage, colorSpace: CGColorSpace, keepPixels: Bool,
                     cornerRadiusPixels: CGFloat = 0) throws -> (MTLTexture, PixelData?) {
        var width = image.width
        var height = image.height
        guard width > 0, height > 0 else { throw RenderError.texture("empty image (\(width)x\(height))") }
        let maxDim = LiquidRenderer.maxTextureDimension
        var radius = cornerRadiusPixels
        if width > maxDim || height > maxDim {
            let factor = Double(maxDim) / Double(max(width, height))
            width = max(1, Int(Double(width) * factor))
            height = max(1, Int(Double(height) * factor))
            radius *= CGFloat(factor)
            logWarning("Image scaled down to \(width)x\(height) (too large for the GPU)")
        }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            ctx.interpolationQuality = .high
            if radius > 0 {
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.clip()
            }
            ctx.draw(image, in: rect)
            return true
        }
        guard drawn else { throw RenderError.texture("could not create CGContext") }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw RenderError.texture("could not create a \(width)x\(height) texture")
        }
        bytes.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                withBytes: base, bytesPerRow: bytesPerRow)
            }
        }
        let pixels = keepPixels ? PixelData(width: width, height: height, bytesPerRow: bytesPerRow, bytes: bytes) : nil
        return (texture, pixels)
    }
}

/// GPU resources and draw logic for one animation.
final class LiquidRenderSession {
    let renderer: LiquidRenderer
    let scene: LiquidScene
    private let windowTexture: MTLTexture
    private let backgroundTexture: MTLTexture?
    private let particleBuffer: MTLBuffer?
    private var fluidTexture: MTLTexture?

    init(renderer: LiquidRenderer, scene: LiquidScene, windowTexture: MTLTexture, backgroundTexture: MTLTexture?) throws {
        precondition(MemoryLayout<LiquidParticle>.stride == 64, "LiquidParticle layout does not match the shader")
        precondition(MemoryLayout<LiquidUniforms>.stride == 160, "LiquidUniforms layout does not match the shader")
        self.renderer = renderer
        self.scene = scene
        self.windowTexture = windowTexture
        self.backgroundTexture = backgroundTexture
        if scene.particles.isEmpty {
            particleBuffer = nil
        } else {
            let length = scene.particles.count * MemoryLayout<LiquidParticle>.stride
            guard let buffer = scene.particles.withUnsafeBytes({ raw -> MTLBuffer? in
                guard let base = raw.baseAddress else { return nil }
                return renderer.device.makeBuffer(bytes: base, length: length, options: .storageModeShared)
            }) else {
                throw RenderError.encoding("could not create particle buffer (\(length) bytes)")
            }
            buffer.label = "particles"
            particleBuffer = buffer
        }
    }

    /// Fluid texture: one texel per point of the overlay.
    private func fluidTarget() throws -> MTLTexture {
        let w = max(1, Int((scene.input.viewSize.width * CGFloat(scene.fluidScale)).rounded(.up)))
        let h = max(1, Int((scene.input.viewSize.height * CGFloat(scene.fluidScale)).rounded(.up)))
        if let existing = fluidTexture, existing.width == w, existing.height == h { return existing }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LiquidRenderer.fluidFormat, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let texture = renderer.device.makeTexture(descriptor: desc) else {
            throw RenderError.texture("could not create fluid texture \(w)x\(h)")
        }
        texture.label = "fluid"
        fluidTexture = texture
        return texture
    }

    /// Encodes both passes. `target` must be a `.bgra8Unorm` render target covering the overlay.
    func encode(into commandBuffer: MTLCommandBuffer, target: MTLTexture, time: Float) throws {
        guard target.width > 0, target.height > 0 else { throw RenderError.encoding("empty render target") }
        let fluid = try fluidTarget()
        let scaleX = Float(target.width) / Float(scene.input.viewSize.width)
        let scaleY = Float(target.height) / Float(scene.input.viewSize.height)
        let t = time.isFinite ? min(max(time, 0), scene.totalDuration) : scene.totalDuration
        var uniforms = scene.uniforms(time: t, scaleX: scaleX, scaleY: scaleY,
                                      fluidTexel: SIMD2(1 / Float(fluid.width), 1 / Float(fluid.height)))
        let uniformLength = MemoryLayout<LiquidUniforms>.stride

        // Pass 1: splat the drops into the fluid field.
        let splatPass = MTLRenderPassDescriptor()
        splatPass.colorAttachments[0].texture = fluid
        splatPass.colorAttachments[0].loadAction = .clear
        splatPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        splatPass.colorAttachments[0].storeAction = .store
        guard let splat = commandBuffer.makeRenderCommandEncoder(descriptor: splatPass) else {
            throw RenderError.encoding("splat encoder")
        }
        splat.label = "splat"
        if let particleBuffer, !scene.particles.isEmpty {
            splat.setRenderPipelineState(renderer.splatPipeline)
            splat.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            splat.setVertexBytes(&uniforms, length: uniformLength, index: 1)
            splat.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: scene.particles.count)
        }
        splat.endEncoding()

        // Pass 2: compose everything into the target.
        let compositePass = MTLRenderPassDescriptor()
        compositePass.colorAttachments[0].texture = target
        compositePass.colorAttachments[0].loadAction = .dontCare
        compositePass.colorAttachments[0].storeAction = .store
        guard let composite = commandBuffer.makeRenderCommandEncoder(descriptor: compositePass) else {
            throw RenderError.encoding("composite encoder")
        }
        composite.label = "composite"
        composite.setRenderPipelineState(renderer.compositePipeline)
        composite.setFragmentTexture(fluid, index: 0)
        composite.setFragmentTexture(windowTexture, index: 1)
        composite.setFragmentTexture(backgroundTexture ?? renderer.emptyTexture, index: 2)
        composite.setFragmentSamplerState(renderer.zeroSampler, index: 0)
        composite.setFragmentSamplerState(renderer.edgeSampler, index: 1)
        composite.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        composite.endEncoding()
    }

    /// Renders one frame offscreen and returns the BGRA pixels (used by the self-test).
    func renderOffscreen(time: Float, pixelWidth: Int, pixelHeight: Int) throws -> PixelData {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LiquidRenderer.outputFormat,
                                                            width: pixelWidth, height: pixelHeight, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .managed
        guard let target = renderer.device.makeTexture(descriptor: desc),
              let commandBuffer = renderer.queue.makeCommandBuffer() else {
            throw RenderError.encoding("offscreen target")
        }
        try encode(into: commandBuffer, target: target, time: time)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw RenderError.encoding(error.localizedDescription) }
        let bytesPerRow = pixelWidth * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * pixelHeight)
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                target.getBytes(base, bytesPerRow: bytesPerRow,
                                from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight), mipmapLevel: 0)
            }
        }
        return PixelData(width: pixelWidth, height: pixelHeight, bytesPerRow: bytesPerRow, bytes: bytes)
    }
}
