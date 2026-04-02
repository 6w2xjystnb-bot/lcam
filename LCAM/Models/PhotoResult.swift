// PhotoResult.swift — результат съёмки с метаданными обработки

import UIKit
import CoreLocation

// Итоговый результат: финальное изображение + вся информация о съёмке
struct PhotoResult: Identifiable {
    let id: UUID
    let finalImage: UIImage         // финальное обработанное изображение
    let thumbnailImage: UIImage     // уменьшенная копия для галереи
    let exif: ExifMetadata
    let processingInfo: ProcessingInfo
    let timestamp: Date

    init(
        finalImage: UIImage,
        exif: ExifMetadata,
        processingInfo: ProcessingInfo
    ) {
        self.id = UUID()
        self.finalImage = finalImage
        self.thumbnailImage = finalImage.thumbnail(maxDimension: 512)
        self.exif = exif
        self.processingInfo = processingInfo
        self.timestamp = Date()
    }
}

// EXIF-данные с камеры (реальные значения из AVFoundation)
struct ExifMetadata {
    var iso: Int
    var shutterSpeed: Double        // в секундах (например, 0.00833 = 1/120)
    var aperture: Double            // f-число
    var focalLength: Double         // мм (эквивалент ФФ)
    var brightnessValue: Double     // EV из метаданных
    var flashFired: Bool
    var colorSpace: String
    var captureMode: CaptureMode
    var location: CLLocation?

    // Форматирование для UI
    var shutterSpeedDisplayString: String {
        if shutterSpeed >= 1.0 {
            return String(format: "%.1fs", shutterSpeed)
        } else {
            let fraction = Int(1.0 / shutterSpeed)
            return "1/\(fraction)s"
        }
    }

    var isoDisplayString: String { "ISO \(iso)" }
    var apertureDisplayString: String { String(format: "f/%.1f", aperture) }
}

// Полная информация о вычислительной обработке
struct ProcessingInfo {
    var capturedFrameCount: Int         // сколько кадров захвачено
    var alignedFrameCount: Int          // сколько выровнено успешно
    var rejectedFrameCount: Int         // отброшено из-за смаза/движения
    var processingTimeMs: Double        // время обработки в мс
    var noiseReductionGain: Float       // во сколько раз снижен шум
    var hdrDynamicRange: Float          // расширение динамического диапазона в EV
    var nightModeUsed: Bool
    var hdrUsed: Bool
    var portraitDepthUsed: Bool
    var algorithmsApplied: [String]     // список применённых алгоритмов

    // Для отображения в UI
    var summaryString: String {
        var parts: [String] = []
        if nightModeUsed { parts.append("Night") }
        if hdrUsed { parts.append("HDR+") }
        if alignedFrameCount > 1 {
            parts.append("\(alignedFrameCount)×")
        }
        parts.append(String(format: "%.0fms", processingTimeMs))
        return parts.joined(separator: " · ")
    }
}

// Расширение UIImage для создания миниатюр
extension UIImage {
    func thumbnail(maxDimension: CGFloat) -> UIImage {
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
