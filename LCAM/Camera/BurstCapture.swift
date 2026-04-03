// BurstCapture.swift — многокадровый захват N фотографий подряд

import AVFoundation
import UIKit

// Захватывает N кадров через AVCapturePhotoOutput и собирает их CVPixelBuffer
// Кадры снимаются с минимальным интервалом для максимального SNR при слиянии
final class BurstCapture: NSObject {

    private let photoOutput:  AVCapturePhotoOutput
    private let targetFrames: Int
    private let captureMode:  CaptureMode
    private let flashMode:    AVCaptureDevice.FlashMode

    private var collectedBuffers: [Int: CVPixelBuffer] = [:] // порядковый → буфер
    private var collectedExif:    ExifMetadata?
    private var pendingCount = 0
    private var fireCount    = 0

    private var progressCallback:    ((Float) -> Void)?
    private var completionCallback:  (([CVPixelBuffer], ExifMetadata) -> Void)?

    private let captureQueue = DispatchQueue(label: "lcam.burst", qos: .userInitiated)

    @MainActor
    init(photoOutput: AVCapturePhotoOutput, targetFrames: Int, settings: CameraSettings) {
        self.photoOutput  = photoOutput
        self.targetFrames = max(1, targetFrames)
        self.captureMode  = settings.captureMode
        self.flashMode    = settings.flashMode
    }

    // Запуск: сначала делаем один тестовый кадр, потом остальные через небольшой интервал
    func start(
        progress:   @escaping (Float) -> Void,
        completion: @escaping ([CVPixelBuffer], ExifMetadata) -> Void
    ) {
        self.progressCallback   = progress
        self.completionCallback = completion
        pendingCount = targetFrames

        captureQueue.async { [weak self] in
            self?.fireNextFrame()
        }
    }

    // Отправляем кадры с небольшим интервалом, чтобы дать ISP стабилизироваться
    // между захватами (особенно важно в ночном режиме)
    private func fireNextFrame() {
        guard fireCount < targetFrames else { return }

        let index = fireCount
        fireCount += 1

        let photoSettings = buildPhotoSettings(index: index)
        // Храним индекс в метаданных через uniqueID (hack: используем uniqueID для маппинга)
        // На самом деле, мы сохраняем соответствие uniqueID → index в словаре
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.pendingUniqueIDs[photoSettings.uniqueID] = index
            DispatchQueue.main.async {
                self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
            }
        }

        // Небольшой интервал между кадрами: в ночном режиме — больше, чтобы AE устаканилось
        if fireCount < targetFrames {
            let delay = captureMode == .night ? 0.08 : 0.03
            captureQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.fireNextFrame()
            }
        }
    }

    // Словарь uniqueID → порядковый номер кадра
    private var pendingUniqueIDs: [Int64: Int] = [:]

    // Строим настройки для каждого кадра
    // Для ночного режима первый кадр — с увеличенной выдержкой для оценки,
    // остальные — стандартные короткие для стекинга
    private func buildPhotoSettings(index: Int) -> AVCapturePhotoSettings {
        // Формат: 32BGRA для прямого доступа к CVPixelBuffer
        let format: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let ps: AVCapturePhotoSettings
        if photoOutput.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
            ps = AVCapturePhotoSettings(format: format)
        } else {
            ps = AVCapturePhotoSettings()
        }

        ps.isHighResolutionPhotoEnabled  = true
        ps.photoQualityPrioritization    = .quality

        // Вспышка только для первого кадра (и только если включена)
        ps.flashMode = (index == 0 && flashMode == .on) ? .on : .off

        return ps
    }

    // Проверяем — дождались ли всех ответов от AVFoundation
    // Используем pendingCount == 0, а не received == total:
    // один упавший кадр не должен блокировать весь бёрст
    private func checkCompletion() {
        let received = collectedBuffers.count
        let total    = targetFrames

        progressCallback?(Float(received) / Float(max(total, 1)))

        guard pendingCount == 0 else { return }

        // Сортируем буферы по порядковому номеру (пропускаем упавшие кадры)
        let sorted = (0..<total).compactMap { collectedBuffers[$0] }

        guard !sorted.isEmpty, let exif = collectedExif else { return }
        completionCallback?(sorted, exif)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension BurstCapture: AVCapturePhotoCaptureDelegate {

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil else {
            pendingCount -= 1
            captureQueue.async { self.checkCompletion() }
            return
        }

        // Получаем порядковый номер из нашего словаря
        let index = pendingUniqueIDs[photo.resolvedSettings.uniqueID] ?? 0
        pendingUniqueIDs.removeValue(forKey: photo.resolvedSettings.uniqueID)
        pendingCount -= 1

        // Забираем CVPixelBuffer напрямую (не конвертируем через JPEG, нет потерь)
        if let pixelBuffer = photo.pixelBuffer {
            collectedBuffers[index] = pixelBuffer
        } else if let data = photo.fileDataRepresentation(),
                  let uiImage = UIImage(data: data),
                  let cgImage = uiImage.cgImage {
            // Фолбэк: конвертируем CGImage → CVPixelBuffer
            if let buffer = cgImage.toCVPixelBuffer() {
                collectedBuffers[index] = buffer
            }
        }

        // Заполняем EXIF из первого успешно полученного кадра
        if collectedExif == nil {
            collectedExif = ExifMetadata(from: photo, captureMode: captureMode)
        }

        captureQueue.async { self.checkCompletion() }
    }
}

// MARK: - Вспомогательные расширения

extension ExifMetadata {
    // Инициализация из AVCapturePhoto
    init(from photo: AVCapturePhoto, captureMode: CaptureMode) {
        let exif = photo.metadata["{Exif}"] as? [String: Any]
        let tiff = photo.metadata["{TIFF}"]  as? [String: Any]
        _ = tiff

        self.iso             = (exif?["ISOSpeedRatings"] as? [Int])?.first ?? 100
        self.shutterSpeed    = (exif?["ExposureTime"] as? Double) ?? (1.0 / 60.0)
        self.aperture        = (exif?["FNumber"] as? Double) ?? 1.8
        self.focalLength     = (exif?["FocalLength"] as? Double) ?? 26.0
        self.brightnessValue = (exif?["BrightnessValue"] as? Double) ?? 0.0
        self.flashFired      = ((exif?["Flash"] as? Int) ?? 0) != 0
        self.colorSpace      = "sRGB"
        self.captureMode     = captureMode
        self.location        = nil
    }
}

extension CGImage {
    // Конвертация CGImage → CVPixelBuffer (32BGRA)
    func toCVPixelBuffer() -> CVPixelBuffer? {
        let w = width, h = height
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, w, h,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}
