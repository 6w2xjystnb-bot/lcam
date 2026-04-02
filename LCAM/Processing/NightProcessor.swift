// NightProcessor.swift — ночной режим (аналог Google Night Sight)
//
// Ключевой принцип: стекинг 20-30 коротких кадров → виртуально длинная выдержка
// без смаза. Стекинг N кадров снижает шум в √N раз: 25 кадров = 5× меньше шума.
// Плюс агрессивное шумоподавление на основе BM3D-подобной логики через CoreImage.

import CoreImage
import CoreVideo
import Metal
import UIKit
import Accelerate

final class NightProcessor {

    private let ciContext: CIContext
    private let device:    MTLDevice

    // Порог для детекции смаза: кадры с большим движением объектов отбрасываются
    private let blurRejectionThreshold: Float = 60.0

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice() else { return nil }
        self.device    = dev
        self.ciContext = CIContext(mtlDevice: dev, options: [.workingColorSpace: NSNull()])
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

    // MARK: - Многопроходное шумоподавление

    private func applyDenoising(to buffer: CVPixelBuffer, strength: Float) -> CVPixelBuffer? {
        var image = CIImage(cvPixelBuffer: buffer)

        // Проход 1: Медианный фильтр (удаляет salt-and-pepper шум)
        image = image.applyingFilter("CIMedianFilter")

        // Проход 2: Гауссово размытие очень малого радиуса + восстановление через НМ
        // Это эмулирует guided filter для шумоподавления
        let blurRadius = CGFloat(strength * 1.8 + 0.5)
        let blurred    = image.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurRadius])

        // НМ: восстанавливаем края из оригинала
        let sharpenAfterBlur = blurred
            .applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius":    blurRadius * 0.5,
                "inputIntensity": CGFloat(strength * 0.4),
                "inputThreshold": 0.03
            ])

        // Проход 3: Noise Reduction фильтр CoreImage (только iOS 12+)
        let noiseReduced = sharpenAfterBlur
            .applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel":  CGFloat(strength * 0.05),
                "inputSharpness":   CGFloat(0.4 + strength * 0.3)
            ])

        // Рендерим в новый буфер
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        var output: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary,
            &output
        )
        guard let output else { return buffer }
        ciContext.render(noiseReduced, to: output)
        return output
    }

    // MARK: - Ночная цветовая обработка

    private func applyNightColorScience(to buffer: CVPixelBuffer, shadowLift: Float) -> CVPixelBuffer? {
        let image = CIImage(cvPixelBuffer: buffer)

        // Подъём экспозиции: ночные снимки должны выглядеть снятыми "как днём"
        // Night Sight Google поднимает яркость довольно агрессивно
        let exposureAdjusted = image
            .applyingFilter("CIExposureAdjust", parameters: [
                "inputEV": CGFloat(shadowLift * 8.0 + 0.3)
            ])

        // Тональная кривая ночи: сильно поднимаем тени, меньше трогаем света
        let toneCurve = exposureAdjusted
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0,  y: 0.0),
                "inputPoint1": CIVector(x: 0.1,  y: CGFloat(0.1 + Double(shadowLift) * 1.5)),
                "inputPoint2": CIVector(x: 0.3,  y: CGFloat(0.35 + Double(shadowLift))),
                "inputPoint3": CIVector(x: 0.7,  y: 0.72),
                "inputPoint4": CIVector(x: 1.0,  y: 1.0)
            ])

        // Небольшое потепление (Night Sight добавляет тепла к ночным сценам)
        let warmed = toneCurve
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral":        CIVector(x: 6500, y: 0),
                "inputTargetNeutral":  CIVector(x: 5800, y: 0)
            ])

        // Виньетирование — лёгкое затемнение краёв для художественного эффекта
        let width  = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        let vignetted = warmed
            .applyingFilter("CIVignette", parameters: [
                "inputIntensity": 0.3,
                "inputRadius":    min(width, height) * 0.7
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
        ciContext.render(vignetted, to: output)
        return output
    }
}
