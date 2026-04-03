// NightProcessor.swift — ночной режим (аналог Google Night Sight)
//
// Ключевой принцип: стекинг 20-30 коротких кадров → виртуально длинная выдержка
// без смаза. Стекинг N кадров снижает шум в √N раз: 25 кадров = 5× меньше шума.
// Плюс агрессивное шумоподавление на основе BM3D-подобной логики через CoreImage.

import CoreImage
import CoreVideo
import Metal
import MetalPerformanceShaders
import UIKit
import Accelerate

final class NightProcessor {

    private let ciContext:     CIContext
    private let device:        MTLDevice
    private let commandQueue:  MTLCommandQueue

    // Порог для детекции смаза: кадры с большим движением объектов отбрасываются
    private let blurRejectionThreshold: Float = 60.0

    init?() {
        guard let dev   = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue()
        else { return nil }
        self.device       = dev
        self.commandQueue = queue
        self.ciContext    = CIContext(mtlDevice: dev, options: [.workingColorSpace: NSNull()])
    }

    // MARK: - Основной метод

    /// frames: уже выровненные кадры (FrameAligner уже отработал)
    /// settings: пользовательские настройки
    func process(frames: [AlignedFrame], settings: CameraSettings) async -> CVPixelBuffer? {
        guard !frames.isEmpty else { return nil }

        // Захватываем @MainActor-изолированные настройки до фоновой обработки
        let (noiseStrength, shadowLift) = await MainActor.run {
            (settings.noiseReductionStrength, settings.shadowLift)
        }

        // 1. Отбираем только хорошие кадры (не смазанные, не со слишком большим движением)
        let goodFrames = frames.filter { $0.alignmentScore > 0.25 && $0.motionMagnitude < blurRejectionThreshold }
        let framesToStack = goodFrames.isEmpty ? [frames[0]] : goodFrames

        // 2. Простой стекинг: среднее по всем хорошим кадрам (максимальный SNR)
        guard let stacked = stackFrames(framesToStack) else { return frames[0].pixelBuffer }

        // 3. Агрессивное шумоподавление — несколько проходов CoreImage
        guard let denoised = applyDenoising(to: stacked, strength: noiseStrength) else {
            return stacked
        }

        // 4. Ночная цветовая обработка:
        //    - Более тёплый ББ (Night Sight слегка делает ночь теплее)
        //    - Подъём теней (делаем ночные снимки светлее)
        //    - Восстановление деталей через резкость
        let final = applyNightColorScience(to: denoised, shadowLift: shadowLift)

        return final ?? denoised
    }

    // MARK: - Простое попиксельное среднее (стекинг)

    private func stackFrames(_ frames: [AlignedFrame]) -> CVPixelBuffer? {
        guard let first = frames.first?.pixelBuffer else { return nil }
        let width  = CVPixelBufferGetWidth(first)
        let height = CVPixelBufferGetHeight(first)

        // Аккумулятор в Float32 для точного сложения
        var accumR = [Float](repeating: 0, count: width * height)
        var accumG = [Float](repeating: 0, count: width * height)
        var accumB = [Float](repeating: 0, count: width * height)

        var validCount = 0

        for frame in frames {
            let buf = frame.pixelBuffer
            guard CVPixelBufferGetWidth(buf) == width,
                  CVPixelBufferGetHeight(buf) == height
            else { continue }

            CVPixelBufferLockBaseAddress(buf, .readOnly)
            guard let base = CVPixelBufferGetBaseAddress(buf) else {
                CVPixelBufferUnlockBaseAddress(buf, .readOnly)
                continue
            }

            let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
            let ptr = base.assumingMemoryBound(to: UInt8.self)

            // Формат BGRA: байты [B, G, R, A]
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    let idx    = y * width + x
                    accumB[idx] += Float(ptr[offset + 0]) / 255.0
                    accumG[idx] += Float(ptr[offset + 1]) / 255.0
                    accumR[idx] += Float(ptr[offset + 2]) / 255.0
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, .readOnly)
            validCount += 1
        }

        guard validCount > 0 else { return first }

        let n = Float(validCount)

        // Создаём выходной буфер
        var outputBuf: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary,
            &outputBuf
        )
        guard let outputBuf else { return first }

        CVPixelBufferLockBaseAddress(outputBuf, [])
        guard let outBase = CVPixelBufferGetBaseAddress(outputBuf) else {
            CVPixelBufferUnlockBaseAddress(outputBuf, [])
            return first
        }

        let outBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuf)
        let outPtr = outBase.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let srcIdx = y * width + x
                let dstOff = y * outBytesPerRow + x * 4
                outPtr[dstOff + 0] = UInt8(min(accumB[srcIdx] / n * 255.0, 255.0))
                outPtr[dstOff + 1] = UInt8(min(accumG[srcIdx] / n * 255.0, 255.0))
                outPtr[dstOff + 2] = UInt8(min(accumR[srcIdx] / n * 255.0, 255.0))
                outPtr[dstOff + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(outputBuf, [])
        return outputBuf
    }

    // MARK: - Bilateral spatial denoising (MPS)

    /// Edge-preserving bilateral filter через Metal Performance Shaders.
    /// Для ночных фото (высокое ISO) используем более агрессивные параметры
    /// чем для дневных: σ_color=0.12, σ_texture=3.5, kernel 9×9.
    ///
    /// Принцип: пиксели с похожим цветом усредняются → шум исчезает в небе/коже/стенах.
    /// Пиксели с разным цветом (настоящий край) не смешиваются → края остаются чёткими.
    /// Это то, что делает Google Camera для ночных снимков.
    private func applyDenoising(to buffer: CVPixelBuffer, strength: Float) -> CVPixelBuffer? {
        let width  = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        var output: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary,
            &output
        )
        guard let output else { return buffer }

        // Создаём Metal-текстуры из CVPixelBuffer (zero-copy, shared memory)
        var texCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &texCache)
        guard let texCache else { return buffer }

        func makeTexture(_ buf: CVPixelBuffer) -> MTLTexture? {
            let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
            var ref: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, texCache, buf, nil, .bgra8Unorm, w, h, 0, &ref
            )
            guard let ref else { return nil }
            return CVMetalTextureGetTexture(ref)
        }

        guard let srcTex = makeTexture(buffer),
              let dstTex = makeTexture(output)
        else { return buffer }

        // Ночной режим: σ_color чуть больше (больше шума надо убрать),
        // σ_texture больше (более широкое пространственное сглаживание)
        let sigmaColor:   Float = 0.10 + strength * 0.04   // 0.10–0.14
        let sigmaTexture: Float = 2.5  + strength * 2.0    // 2.5–4.5
        let diameter = sigmaTexture > 3.5 ? 9 : 7

        let blur = MPSImageBilateralBlur(device: device,
                                         kernelDiameter: diameter,
                                         sigmaColor: sigmaColor,
                                         sigmaTexture: sigmaTexture)
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return buffer }
        blur.encode(commandBuffer: cmdBuf, sourceTexture: srcTex, destinationTexture: dstTex)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return output
    }

    // MARK: - Ночная цветовая обработка

    private func applyNightColorScience(to buffer: CVPixelBuffer, shadowLift: Float) -> CVPixelBuffer? {
        let image = CIImage(cvPixelBuffer: buffer)

        // CIHighlightShadowAdjust: подъём теней + мягкое восстановление светов
        // Не трогает белый баланс, не вносит цветовых сдвигов
        let hdrAdjusted = image
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 0.6,
                "inputShadowAmount":    CGFloat(shadowLift * 6.0)
            ])

        // +0.5 EV для ночи — Night Sight делает ночь светлее, но без артефактов
        let exposed = hdrAdjusted
            .applyingFilter("CIExposureAdjust", parameters: [
                "inputEV": CGFloat(0.4 + Double(shadowLift) * 1.5)
            ])

        // Насыщенность: ночью чуть насыщеннее (Night Sight поднимает цвета),
        // но без CIUnsharpMask — он добавляет ореолы и зернистость.
        let colored = exposed
            .applyingFilter("CIColorControls", parameters: [
                "inputSaturation": 1.15,
                "inputBrightness": 0.0,
                "inputContrast":   1.04
            ])

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        var output: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary,
            &output
        )
        guard let output else { return buffer }
        ciContext.render(colored, to: output)
        return output
    }
}
