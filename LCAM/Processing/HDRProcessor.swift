// HDRProcessor.swift — HDR+ многокадровое слияние с моделью шума
//
// Алгоритм (аналог Google HDR+):
//  1. Принимаем N выровненных кадров
//  2. Для каждого пикселя вычисляем вес: exp(-||Δ||² / (2σ²))
//     где σ² — ожидаемая дисперсия шума (модель: readNoise + shotNoise * signal)
//  3. Слитый пиксель = Σ(w_i * p_i) / Σ(w_i)
//  4. Тональное отображение: глобальное + локальный контраст
//  5. Цветовая обработка: насыщенность, тени/света, резкость

import Metal
import MetalPerformanceShaders
import CoreImage
import CoreVideo
import UIKit

final class HDRProcessor {

    private let device:       MTLDevice
    private let commandQueue: MTLCommandQueue

    // Пайплайны Metal
    private let mergePipeline:     MTLComputePipelineState
    private let normalizePipeline: MTLComputePipelineState
    private let tonemapPipeline:   MTLComputePipelineState

    // CoreImage контекст для финальных фильтров (работает на GPU)
    private let ciContext: CIContext

    init?() {
        guard let dev   = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue()
        else { return nil }
        self.device       = dev
        self.commandQueue = queue
        self.ciContext    = CIContext(mtlDevice: dev, options: [.workingColorSpace: NSNull()])

        guard let merge     = HDRProcessor.compilePipeline(device: dev, functionName: "mergeFrames"),
              let normalize = HDRProcessor.compilePipeline(device: dev, functionName: "normalizeMerge"),
              let tonemap   = HDRProcessor.compilePipeline(device: dev, functionName: "localToneMap")
        else { return nil }

        self.mergePipeline     = merge
        self.normalizePipeline = normalize
        self.tonemapPipeline   = tonemap
    }

    // MARK: - Главный метод HDR+ слияния

    /// frames: уже выровненные кадры (из FrameAligner)
    /// scores: веса качества выравнивания [0..1] для каждого кадра
    func process(
        frames: [AlignedFrame],
        settings: CameraSettings
    ) async -> CVPixelBuffer? {
        guard !frames.isEmpty else { return nil }

        // Если один кадр — применяем только тональное отображение
        if frames.count == 1 {
            return await applyToneMapping(
                to: frames[0].pixelBuffer,
                settings: settings
            )
        }

        // 1. Слияние кадров с взвешиванием по шуму
        guard let merged = mergeFrames(frames: frames, settings: settings) else {
            return frames[0].pixelBuffer
        }

        // 2. Тональное отображение
        guard let toned = await applyToneMapping(to: merged, settings: settings) else {
            return merged
        }

        return toned
    }

    // MARK: - Metal: взвешенное слияние кадров

    private func mergeFrames(frames: [AlignedFrame], settings: CameraSettings) -> CVPixelBuffer? {
        guard let ref = frames.first?.pixelBuffer else { return nil }
        let width  = CVPixelBufferGetWidth(ref)
        let height = CVPixelBufferGetHeight(ref)

        // Создаём аккумуляторы: sumWeightedColor и sumWeight (текстуры Float)
        guard let (accumRGB, accumW) = makeAccumulatorTextures(width: width, height: height),
              let outputBuffer = createPixelBuffer(width: width, height: height)
        else { return nil }

        let texCache = makeTextureCache()

        // Параметры модели шума → передаём в Metal
        var noiseParams = NoiseParams(
            readNoise:  NoiseModel.iPhoneDefault.readNoiseSigmaSquared,
            shotNoise:  NoiseModel.iPhoneDefault.shotNoiseFactor,
            frameCount: UInt32(frames.count)
        )

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return nil }

        // Для каждого кадра: добавляем взвешенный вклад в аккумуляторы
        for (i, frame) in frames.enumerated() {
            guard frame.alignmentScore > 0.1 else { continue }  // пропускаем плохие кадры

            guard let srcTex = makeTexture(from: frame.pixelBuffer, cache: texCache, format: .bgra8Unorm)
            else { continue }

            guard let encoder = cmdBuf.makeComputeCommandEncoder() else { continue }
            encoder.setComputePipelineState(mergePipeline)
            encoder.setTexture(srcTex,    index: 0)   // текущий кадр
            encoder.setTexture(accumRGB,  index: 1)   // аккумулятор цвета
            encoder.setTexture(accumW,    index: 2)   // аккумулятор весов
            encoder.setBytes(&noiseParams, length: MemoryLayout<NoiseParams>.size, index: 0)

            var frameIndex = UInt32(i)
            encoder.setBytes(&frameIndex, length: MemoryLayout<UInt32>.size, index: 1)

            // Для первого кадра передаём его же как опорный
            let refTex = i == 0 ? srcTex : makeTexture(from: frames[0].pixelBuffer, cache: texCache, format: .bgra8Unorm)
            encoder.setTexture(refTex, index: 3)

            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let tgs = MTLSize(width: (width+15)/16, height: (height+15)/16, depth: 1)
            encoder.dispatchThreadgroups(tgs, threadsPerThreadgroup: tg)
            encoder.endEncoding()
        }

        // Финальный проход: normalizeMerge → делим на сумму весов → пишем в outputBuffer
        if let outTex = makeTexture(from: outputBuffer, cache: texCache, format: .bgra8Unorm),
           let encoder = cmdBuf.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(normalizePipeline)
            encoder.setTexture(accumRGB, index: 0)
            encoder.setTexture(accumW,   index: 1)
            encoder.setTexture(outTex,   index: 2)
            let tg  = MTLSize(width: 16, height: 16, depth: 1)
            let tgs = MTLSize(width: (width+15)/16, height: (height+15)/16, depth: 1)
            encoder.dispatchThreadgroups(tgs, threadsPerThreadgroup: tg)
            encoder.endEncoding()
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return outputBuffer
    }

    // MARK: - CoreImage: тональное отображение + цветовая обработка

    private func applyToneMapping(
        to buffer: CVPixelBuffer,
        settings: CameraSettings
    ) async -> CVPixelBuffer? {
        let (shadowLift, highlightRecovery, saturationBoost, sharpeningStrength) = await MainActor.run {
            (settings.shadowLift, settings.highlightRecovery, settings.saturationBoost, settings.sharpeningStrength)
        }

        let ci = CIImage(cvPixelBuffer: buffer)

        // CIHighlightShadowAdjust — Apple's собственный HDR-фильтр.
        // inputHighlightAmount < 1.0 восстанавливает пересвет;
        // inputShadowAmount > 0 поднимает тени.
        // Не трогает мидтоны и не вносит цветовых сдвигов.
        let hdrAdjusted = ci
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": CGFloat(max(0.0, 1.0 - Double(highlightRecovery) * 0.6)),
                "inputShadowAmount":    CGFloat(shadowLift * 4.0)
            ])

        // Лёгкое усиление насыщенности без цветового сдвига
        let colored = hdrAdjusted
            .applyingFilter("CIColorControls", parameters: [
                "inputSaturation": CGFloat(1.0 + Double(saturationBoost) * 0.5),
                "inputBrightness": 0.0,
                "inputContrast":   1.02
            ])

        // Адаптивная резкость — небольшой радиус, чтобы не было ореолов
        let sharpened = colored
            .applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius":    1.5,
                "inputIntensity": CGFloat(sharpeningStrength * 0.55)
            ])

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard let result = createPixelBuffer(width: w, height: h) else { return buffer }

        ciContext.render(sharpened, to: result)
        return result
    }

    // MARK: - Metal helpers

    private func makeAccumulatorTextures(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
        )
        desc.usage       = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared  // CPU-accessible так что можно явно обнулить

        let wDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        wDesc.usage       = [.shaderRead, .shaderWrite]
        wDesc.storageMode = .shared

        guard let rgb = device.makeTexture(descriptor: desc),
              let w   = device.makeTexture(descriptor: wDesc) else { return nil }

        // Явное обнуление: начальное содержимое Metal-текстур не определено по спецификации.
        // Без этого аккумулятор накапливает мусор → артефакты в слитом кадре.
        let rgbZeros = [Float](repeating: 0, count: width * height * 4)
        let wZeros   = [Float](repeating: 0, count: width * height)
        rgb.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: rgbZeros,
                    bytesPerRow: width * 4 * MemoryLayout<Float>.size)
        w.replace(region: MTLRegionMake2D(0, 0, width, height),
                  mipmapLevel: 0,
                  withBytes: wZeros,
                  bytesPerRow: width * MemoryLayout<Float>.size)

        return (rgb, w)
    }

    private func makeTextureCache() -> CVMetalTextureCache {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        return cache!
    }

    private func makeTexture(
        from buffer: CVPixelBuffer, cache: CVMetalTextureCache, format: MTLPixelFormat
    ) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, format, w, h, 0, &tex
        )
        guard let tex else { return nil }
        return CVMetalTextureGetTexture(tex)
    }

    private func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary,
            &buf
        )
        return buf
    }

    // MARK: - Компиляция Metal-функции из встроенного источника

    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct NoiseParams {
        float readNoise;
        float shotNoise;
        uint  frameCount;
    };

    // Добавляем взвешенный вклад кадра в аккумулятор
    kernel void mergeFrames(
        texture2d<float, access::read>       srcFrame  [[texture(0)]],
        texture2d<float, access::read_write> accumRGB  [[texture(1)]],
        texture2d<float, access::read_write> accumW    [[texture(2)]],
        constant NoiseParams&                noise     [[buffer(0)]],
        constant uint&                       frameIdx  [[buffer(1)]],
        texture2d<float, access::read>       refFrame  [[texture(3)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= srcFrame.get_width() || gid.y >= srcFrame.get_height()) return;

        float4 px  = srcFrame.read(gid);
        float4 ref = refFrame.read(gid);

        // Яркость пикселя (для дробового шума)
        float luma = dot(px.rgb, float3(0.2126, 0.7152, 0.0722));
        float sigma2 = noise.readNoise + noise.shotNoise * luma;

        // Разница с опорным кадром: если велика — снижаем вес (детекция движения)
        float4 delta  = px - ref;
        float  delta2 = dot(delta.rgb, delta.rgb);
        float  weight = exp(-delta2 / (2.0 * sigma2 * float(noise.frameCount)));

        // Для первого кадра вес всегда 1.0
        if (frameIdx == 0) weight = 1.0;

        float4 prevRGB = accumRGB.read(gid);
        float  prevW   = accumW.read(gid).r;

        accumRGB.write(prevRGB + weight * px, gid);
        accumW.write(float4(prevW + weight, 0, 0, 0), gid);
    }

    // Нормализация: делим накопленный цвет на сумму весов
    kernel void normalizeMerge(
        texture2d<float, access::read>  accumRGB [[texture(0)]],
        texture2d<float, access::read>  accumW   [[texture(1)]],
        texture2d<float, access::write> output   [[texture(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        float4 rgb = accumRGB.read(gid);
        float  w   = max(accumW.read(gid).r, 1e-6);
        output.write(clamp(rgb / w, 0.0, 1.0), gid);
    }

    // Локальное тональное отображение: поднимаем тени, восстанавливаем света
    kernel void localToneMap(
        texture2d<float, access::read>  input  [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        float4 px   = input.read(gid);
        float  luma = dot(px.rgb, float3(0.2126, 0.7152, 0.0722));

        // S-кривая: тени поднимаем, света сдерживаем
        float mapped = luma < 0.5
            ? 2.0 * luma * luma          // тени: мягкий подъём
            : 1.0 - 2.0*(1.0-luma)*(1.0-luma); // света: мягкое восстановление

        float3 result = luma > 0.001 ? px.rgb * (mapped / luma) : px.rgb;
        output.write(float4(clamp(result, 0.0, 1.0), px.a), gid);
    }
    """

    private static var cachedLibrary: MTLLibrary?

    private static func compilePipeline(device: MTLDevice, functionName: String) -> MTLComputePipelineState? {
        do {
            if cachedLibrary == nil {
                cachedLibrary = try device.makeLibrary(source: metalSource, options: nil)
            }
            guard let fn = cachedLibrary?.makeFunction(name: functionName) else { return nil }
            return try device.makeComputePipelineState(function: fn)
        } catch {
            print("HDRProcessor Metal '\(functionName)' error: \(error)")
            return nil
        }
    }
}

// Структура параметров шума для Metal (должна точно совпадать с MSL struct)
private struct NoiseParams {
    var readNoise:  Float
    var shotNoise:  Float
    var frameCount: UInt32
}
