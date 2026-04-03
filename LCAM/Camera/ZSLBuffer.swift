// ZSLBuffer.swift — Zero Shutter Lag кольцевой буфер
//
// GCam ZSL-принцип: камера непрерывно захватывает кадры в кольцевой буфер.
// При нажатии кнопки НЕ ждём новых кадров — берём уже готовые из буфера.
// Кадры снятые ДО нажатия лучше: устройство было стабильно, палец ещё не сдвинул.
//
// Использование:
//   1. AVCaptureVideoDataOutput → captureOutput → zslBuffer.push()
//   2. capturePhoto() → zslBuffer.takeLast(n) → pipeline
//
// Ограничение: видео-кадры имеют разрешение видеопотока (не полный сенсор).
// Это компромисс скорости vs качества; для хорошего света ZSL приоритетнее.

import AVFoundation
import CoreVideo

final class ZSLBuffer {

    /// Максимум кадров в буфере. 8 = ~0.27с при 30fps.
    /// Меньше — меньше памяти; больше — больше вариантов для выбора.
    static let capacity = 8

    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let timestamp:   CMTime
        let iso:         Float
        let shutterSec:  Double
    }

    private var frames: [Frame] = []
    private let lock   = NSLock()

    // MARK: - Запись

    func push(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime,
              iso: Float = 100, shutterSec: Double = 1.0/60.0) {
        lock.lock()
        defer { lock.unlock() }
        frames.append(Frame(pixelBuffer: pixelBuffer, timestamp: timestamp,
                            iso: iso, shutterSec: shutterSec))
        if frames.count > Self.capacity {
            frames.removeFirst()
        }
    }

    // MARK: - Чтение

    /// Возвращает последние n кадров (от старого к новому — правильный порядок для merge).
    func takeLast(_ n: Int) -> [CVPixelBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return frames.suffix(n).map { $0.pixelBuffer }
    }

    /// Количество накопленных кадров.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    /// Буфер достаточно заполнен для данного количества кадров.
    func isReady(for n: Int) -> Bool {
        return count >= max(2, n / 2)  // нужно хотя бы половину запрошенных кадров
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll()
    }
}
