// RawProcessor.swift — Bayer RAW → линейный RGB через Metal
//
// Фаза 1 реального HDR+ пайплайна:
//   RAW Bayer (kCVPixelFormatType_14Bayer_RGGB) → демозаика → линейный RGB
//
// Почему это важно: Apple ISP уже применил шарпенинг, шумоподавление и
// цветовую обработку к JPEG/BGRA кадрам. RAW — данные ДО всей этой обработки.
// Только работая с RAW можно получить настоящее подавление шума без артефактов.

import Metal
import CoreVideo
import UIKit

final class RawProcessor {

    private let device:       MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline:     MTLComputePipelineState

    // Bayer-паттерн на большинстве iPhone: RGGB
    enum BayerPattern: UInt32 {
        case rggb = 0  // (even,even)=R, (odd,even)=Gr, (even,odd)=Gb, (odd,odd)=B
        case bggr = 1
        case grbg = 2
        case gbrg = 3
    }

    init?() {
        guard let dev   = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue()
        else { return nil }
        self.device       = dev
        self.commandQueue = queue

        guard let pipeline = RawProcessor.buildPipeline(device: dev) else { return nil }
        self.pipeline = pipeline
    }

    // MARK: - Главный метод: RAW CVPixelBuffer → демозаированный CVPixelBuffer (sRGB)

    /// Принимает Bayer RAW буфер (kCVPixelFormatType_14Bayer_RGGB или аналог).
    /// Возвращает kCVPixelFormatType_32BGRA буфер с гамма-кодированным sRGB.
    func demosaic(
        _ rawBuffer: CVPixelBuffer,
        pattern: BayerPattern = .rggb
    ) -> CVPixelBuffer? {
        let rawW = CVPixelBufferGetWidth(rawBuffer)
        let rawH = CVPixelBufferGetHeight(rawBuffer)

        // Создаём Metal-текстуру из RAW-буфера.
        // Формат r16Unorm: каждый Bayer-пиксель = 16-бит (14 значимых, правовыровненных).
        // Нормализация Metal: значение / 65535.0. Для 14-бит макс = 16383 → ~0.25.
        // Шейдер сам применит масштаб 65535/16383 ≈ 4.0.
        guard let srcTex = makeBayerTexture(from: rawBuffer) else { return nil }

        // Выходной BGRA CVPixelBuffer
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var outBuf: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, rawW, rawH,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &outBuf
        ) == kCVReturnSuccess, let outBuf else { return nil }

        // Выходная Metal-текстура
        var texCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &texCache)
        guard let texCache else { return nil }
        var outMetal: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, texCache, outBuf, nil,
            .bgra8Unorm, rawW, rawH, 0, &outMetal
        )
        guard let outMetal,
              let dstTex = CVMetalTextureGetTexture(outMetal)
        else { return nil }

        // Запускаем Metal compute-шейдер
        guard let cmdBuf  = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(srcTex, index: 0)
        encoder.setTexture(dstTex, index: 1)
        var pat = pattern.rawValue
        encoder.setBytes(&pat, length: MemoryLayout<UInt32>.size, index: 0)

        let tg  = MTLSize(width: 16, height: 16, depth: 1)
        let tgs = MTLSize(width: (rawW+15)/16, height: (rawH+15)/16, depth: 1)
        encoder.dispatchThreadgroups(tgs, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return outBuf
    }

    // MARK: - Создание текстуры из RAW Bayer-буфера

    /// Bayer-буфер нельзя создать через CVMetalTextureCache (формат не поддерживается).
    /// Копируем байты напрямую в r16Unorm Metal-текстуру.
    private func makeBayerTexture(from buffer: CVPixelBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Unorm, width: w, height: h, mipmapped: false
        )
        desc.usage       = [.shaderRead]
        desc.storageMode = .shared

        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        tex.replace(
            region:      MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes:   base,
            bytesPerRow: bytesPerRow
        )
        return tex
    }

    // MARK: - Metal пайплайн и MSL-шейдер

    private static func buildPipeline(device: MTLDevice) -> MTLComputePipelineState? {
        let src = """
        #include <metal_stdlib>
        using namespace metal;

        // ─── sRGB гамма-кодирование ───────────────────────────────────────────
        float linearToSRGB(float x) {
            x = clamp(x, 0.0, 1.0);
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0/2.4) - 0.055;
        }

        // ─── Билинейная демозаика Bayer → RGB ────────────────────────────────
        // patten=0: RGGB  (even,even)=R (odd,even)=Gr (even,odd)=Gb (odd,odd)=B
        // Формат входа: r16Unorm, 14-бит значения правовыровнены в 16-бит контейнере.
        // Значения: 0–16383 нормализованы как 0.0–0.25 (max_14bit/max_16bit ≈ 0.25).
        // Нужен scale × 4.0 чтобы привести к полному диапазону [0,1].
        kernel void demosaicBayer(
            texture2d<float, access::read>  bayer   [[texture(0)]],
            texture2d<float, access::write> output  [[texture(1)]],
            constant uint&                  pattern [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            int W = int(bayer.get_width());
            int H = int(bayer.get_height());
            if (int(gid.x) >= W || int(gid.y) >= H) return;

            // Сэмпл из Bayer-текстуры с зажимом к границе
            auto smp = [&](int px, int py) -> float {
                uint2 c = uint2(clamp(px, 0, W-1), clamp(py, 0, H-1));
                return bayer.read(c).r * 4.0;  // 14-бит → полный [0,1]
            };

            int x = int(gid.x), y = int(gid.y);
            int col = x & 1, row = y & 1;

            // Определяем какой канал в этом пикселе (для RGGB):
            // ch=0:R  ch=1:Gr  ch=2:Gb  ch=3:B
            // Для других паттернов применяем XOR-сдвиг
            int ch = col + row * 2;
            if (pattern == 1) { ch = 3 - ch; }          // BGGR: инверсия
            else if (pattern == 2) { ch = ch ^ 1; }     // GRBG: своп R↔Gr, B↔Gb
            else if (pattern == 3) { ch = ch ^ 2; }     // GBRG: своп Gr↔Gb

            float R, G, B;

            if (ch == 0) {          // R-пиксель
                R = smp(x, y);
                G = (smp(x-1,y)+smp(x+1,y)+smp(x,y-1)+smp(x,y+1)) * 0.25;
                B = (smp(x-1,y-1)+smp(x+1,y-1)+smp(x-1,y+1)+smp(x+1,y+1)) * 0.25;
            } else if (ch == 3) {   // B-пиксель
                B = smp(x, y);
                G = (smp(x-1,y)+smp(x+1,y)+smp(x,y-1)+smp(x,y+1)) * 0.25;
                R = (smp(x-1,y-1)+smp(x+1,y-1)+smp(x-1,y+1)+smp(x+1,y+1)) * 0.25;
            } else if (ch == 1) {   // Gr (G в строке R)
                G = smp(x, y);
                R = (smp(x-1,y) + smp(x+1,y)) * 0.5;
                B = (smp(x,y-1) + smp(x,y+1)) * 0.5;
            } else {                // Gb (G в строке B)
                G = smp(x, y);
                B = (smp(x-1,y) + smp(x+1,y)) * 0.5;
                R = (smp(x,y-1) + smp(x,y+1)) * 0.5;
            }

            // Коррекция чёрного уровня: типичный iPhone = 256 отсчётов в 14-бит
            // В нормализованном [0,1]: 256/16383 ≈ 0.0156
            const float black = 256.0 / 16383.0;
            const float white = 1.0;
            const float scale = 1.0 / (white - black);
            R = clamp((R - black) * scale, 0.0, 1.0);
            G = clamp((G - black) * scale, 0.0, 1.0);
            B = clamp((B - black) * scale, 0.0, 1.0);

            // Линейный → sRGB (гамма-кодирование)
            // Это необходимо для корректного отображения; HDR-merge (следующая фаза)
            // будет работать в линейном пространстве до этого шага.
            float r = linearToSRGB(R);
            float g = linearToSRGB(G);
            float b = linearToSRGB(B);

            // BGRA output
            output.write(float4(b, g, r, 1.0), gid);
        }
        """

        do {
            let lib = try device.makeLibrary(source: src, options: nil)
            let fn  = lib.makeFunction(name: "demosaicBayer")!
            return try device.makeComputePipelineState(function: fn)
        } catch {
            print("RawProcessor Metal compile error: \(error)")
            return nil
        }
    }

    // MARK: - Вспомогательные методы

    /// Возвращает первый доступный RAW-формат из списка поддерживаемых AVCapturePhotoOutput.
    /// nil — устройство не поддерживает RAW захват.
    static func bestRawFormat(from photoOutput: AVCapturePhotoOutput) -> OSType? {
        // Предпочитаем 14-бит RGGB; если нет — берём первый доступный
        let preferred: [OSType] = [
            kCVPixelFormatType_14Bayer_RGGB,
            kCVPixelFormatType_14Bayer_BGGR,
            kCVPixelFormatType_14Bayer_GRBG,
            kCVPixelFormatType_14Bayer_GBRG,
        ]
        let available = photoOutput.availableRawPhotoPixelFormatTypes
        for fmt in preferred {
            if available.contains(fmt) { return fmt }
        }
        return available.first
    }

    /// Возвращает Bayer-паттерн по OSType формата.
    static func pattern(for format: OSType) -> BayerPattern {
        switch format {
        case kCVPixelFormatType_14Bayer_RGGB: return .rggb
        case kCVPixelFormatType_14Bayer_BGGR: return .bggr
        case kCVPixelFormatType_14Bayer_GRBG: return .grbg
        case kCVPixelFormatType_14Bayer_GBRG: return .gbrg
        default:                              return .rggb
        }
    }
}
