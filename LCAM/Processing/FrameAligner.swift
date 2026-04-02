// FrameAligner.swift — выравнивание кадров оптическим потоком (Vision framework)
// Каждый кадр из бёрста выравнивается по опорному (первому) кадру.
// Использует VNGenerateOpticalFlowRequest → карту смещений → Metal warp.

import Vision
import CoreImage
import Metal
import MetalPerformanceShaders
import CoreVideo
import UIKit

// Результат выравнивания: буфер + насколько хорошо он выровнялся (0..1)
struct AlignedFrame {
    let pixelBuffer: CVPixelBuffer
    let alignmentScore: Float   // 1.0 = идеально, 0.0 = слишком много движения
    let motionMagnitude: Float  // среднее смещение в пикселях
}

final class FrameAligner {

    // Порог: кадры с движением > этого значения отбрасываются (пикселей)
    var motionRejectionThreshold: Float = 40.0  // для дня 20px, для ночи — 40px

    private let device:        MTLDevice
    private let commandQueue:  MTLCommandQueue
    private let warpPipeline:  MTLComputePipelineState

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else { return nil }
        self.device       = dev
        self.commandQueue = queue

        // Компилируем Metal-шейдер выравнивания (встроен как строка)
        guard let pipeline = FrameAligner.buildWarpPipeline(device: dev) else { return nil }
        self.warpPipeline = pipeline
    }

    // MARK: - Основной метод: выравниваем все кадры по кадру 0

    func align(frames: [CVPixelBuffer]) async -> [AlignedFrame] {
        guard frames.count > 1 else {
            // Один кадр — возвращаем как есть, с идеальным скором
            return frames.map { AlignedFrame(pixelBuffer: $0, alignmentScore: 1.0, motionMagnitude: 0.0) }
        }

        let reference = frames[0]

        var results: [AlignedFrame] = []

        // Опорный кадр без изменений
        results.append(AlignedFrame(pixelBuffer: reference, alignmentScore: 1.0, motionMagnitude: 0.0))

        // Остальные кадры выравниваем по опорному
        for i in 1..<frames.count {
            let aligned = await alignSingle(source: frames[i], reference: reference, index: i)
            results.append(aligned)
        }

        return results
    }

    // MARK: - Выравнивание одного кадра
    private func alignSingle(
        source: CVPixelBuffer,
        reference: CVPixelBuffer,
        index: Int
    ) async -> AlignedFrame {
        // 1. Вычисляем оптический поток Vision
        guard let flowBuffer = computeOpticalFlow(from: source, to: reference) else {
            // Если Vision недоступна — возвращаем кадр как есть с низким скором
            return AlignedFrame(pixelBuffer: source, alignmentScore: 0.5, motionMagnitude: 0.0)
        }

        // 2. Вычисляем среднее смещение (для детекции слишком больших движений)
        let (motionMagnitude, maxMotion) = estimateMotion(flowBuffer: flowBuffer)

        // 3. Если кадр слишком смазан или объект слишком двигался — отбрасываем
        if maxMotion > motionRejectionThreshold * 2.0 {
            return AlignedFrame(pixelBuffer: source, alignmentScore: 0.0, motionMagnitude: motionMagnitude)
        }

        // 4. Применяем warp через Metal
        guard let warped = warpFrame(source: source, flow: flowBuffer) else {
            return AlignedFrame(pixelBuffer: source, alignmentScore: 0.7, motionMagnitude: motionMagnitude)
        }

        // Скор: чем меньше движения — тем лучше
        let score = max(0.0, 1.0 - (motionMagnitude / motionRejectionThreshold))

        return AlignedFrame(pixelBuffer: warped, alignmentScore: score, motionMagnitude: motionMagnitude)
    }

    // MARK: - Vision Optical Flow
    // Возвращает CVPixelBuffer с двухканальной картой Float (dx, dy) для каждого пикселя
    private func computeOpticalFlow(
        from source: CVPixelBuffer,
        to target: CVPixelBuffer
    ) -> CVPixelBuffer? {
        // source → target: вычисляем поток "куда переместился каждый пиксель"
        let request = VNGenerateOpticalFlowRequest(
            targetedCVPixelBuffer: target,
            options: [:]
        )
        request.computationAccuracy = .high  // максимальная точность
        request.keepNetworkOutput   = false

        let handler = VNImageRequestHandler(cvPixelBuffer: source, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first as? VNPixelBufferObservation else {
            return nil
        }
        return observation.pixelBuffer
    }

    // MARK: - Оценка величины движения из карты потока
    private func estimateMotion(flowBuffer: CVPixelBuffer) -> (avgMagnitude: Float, maxMagnitude: Float) {
        CVPixelBufferLockBaseAddress(flowBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flowBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(flowBuffer) else { return (0, 0) }

        let width    = CVPixelBufferGetWidth(flowBuffer)
        let height   = CVPixelBufferGetHeight(flowBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(flowBuffer)

        // Карта потока — двухканальный Float32 (kCVPixelFormatType_TwoComponent32Float)
        let ptr = baseAddress.assumingMemoryBound(to: Float.self)

        var sumMagnitude: Float = 0
        var maxMagnitude: Float = 0
        var count = 0

        // Сэмплируем каждый 4-й пиксель для быстроты
        let step = 4
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let rowOffset = y * (rowBytes / MemoryLayout<Float>.size)
                let pxOffset  = rowOffset + x * 2
                let dx = ptr[pxOffset]
                let dy = ptr[pxOffset + 1]
                let mag = sqrt(dx * dx + dy * dy)
                sumMagnitude += mag
                if mag > maxMagnitude { maxMagnitude = mag }
                count += 1
            }
        }

        let avg = count > 0 ? sumMagnitude / Float(count) : 0
        return (avg, maxMagnitude)
    }

    // MARK: - Metal Warp: применяем карту оптического потока к кадру
    private func warpFrame(source: CVPixelBuffer, flow: CVPixelBuffer) -> CVPixelBuffer? {
        let width  = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)

        // Создаём выходной буфер того же формата
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer
        ) == kCVReturnSuccess, let outputBuffer else { return nil }

        // Текстуры Metal
        let texCache = makeTextureCache()
        guard let srcTex  = makeTexture(from: source,       cache: texCache, pixelFormat: .bgra8Unorm),
              let flowTex = makeTexture(from: flow,          cache: texCache, pixelFormat: .rg32Float),
              let dstTex  = makeTexture(from: outputBuffer,  cache: texCache, pixelFormat: .bgra8Unorm)
        else { return nil }

        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder   = cmdBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(warpPipeline)
        encoder.setTexture(srcTex,  index: 0)
        encoder.setTexture(flowTex, index: 1)
        encoder.setTexture(dstTex,  index: 2)

        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups    = MTLSize(
            width:  (width  + 15) / 16,
            height: (height + 15) / 16,
            depth:  1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        return outputBuffer
    }

    // MARK: - Вспомогательные методы Metal

    private func makeTextureCache() -> CVMetalTextureCache {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        return cache!
    }

    private func makeTexture(
        from buffer: CVPixelBuffer,
        cache: CVMetalTextureCache,
        pixelFormat: MTLPixelFormat
    ) -> MTLTexture? {
        let width  = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var metalTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil,
            pixelFormat, width, height, 0, &metalTex
        )
        guard status == kCVReturnSuccess, let metalTex else { return nil }
        return CVMetalTextureGetTexture(metalTex)
    }

    // Компилируем MSL-шейдер из встроенной строки
    private static func buildWarpPipeline(device: MTLDevice) -> MTLComputePipelineState? {
        let src = """
        #include <metal_stdlib>
        using namespace metal;

        // Билинейная интерполяция пикселя из исходной текстуры
        float4 sampleBilinear(texture2d<float, access::read> tex, float2 coord) {
            int w = int(tex.get_width())  - 1;
            int h = int(tex.get_height()) - 1;
            float2 f  = floor(coord);
            float2 fr = coord - f;
            int2 p00  = clamp(int2(f),            int2(0), int2(w, h));
            int2 p10  = clamp(int2(f) + int2(1,0), int2(0), int2(w, h));
            int2 p01  = clamp(int2(f) + int2(0,1), int2(0), int2(w, h));
            int2 p11  = clamp(int2(f) + int2(1,1), int2(0), int2(w, h));
            float4 c00 = tex.read(uint2(p00));
            float4 c10 = tex.read(uint2(p10));
            float4 c01 = tex.read(uint2(p01));
            float4 c11 = tex.read(uint2(p11));
            return mix(mix(c00, c10, fr.x), mix(c01, c11, fr.x), fr.y);
        }

        kernel void warpFrame(
            texture2d<float, access::read>  srcTex  [[texture(0)]],
            texture2d<float, access::read>  flowTex [[texture(1)]],
            texture2d<float, access::write> dstTex  [[texture(2)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= dstTex.get_width() || gid.y >= dstTex.get_height()) return;

            // Карта потока Vision хранит смещения в нормализованных координатах [-1..1]
            // Конвертируем в пиксельные смещения
            float2 flow = flowTex.read(gid).rg;
            float2 srcCoord = float2(gid) - float2(
                flow.x * float(srcTex.get_width()),
                flow.y * float(srcTex.get_height())
            );

            float4 color = sampleBilinear(srcTex, srcCoord);
            dstTex.write(color, gid);
        }
        """

        do {
            let library  = try device.makeLibrary(source: src, options: nil)
            let function = library.makeFunction(name: "warpFrame")!
            return try device.makeComputePipelineState(function: function)
        } catch {
            print("FrameAligner Metal compile error: \(error)")
            return nil
        }
    }
}
