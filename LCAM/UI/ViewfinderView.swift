// ViewfinderView.swift — превью с камеры + tap-to-focus

import SwiftUI
import AVFoundation

// UIViewRepresentable: отображает AVCaptureVideoPreviewLayer внутри SwiftUI
struct ViewfinderView: UIViewRepresentable {

    let session: AVCaptureSession

    // Коллбэк tap-фокуса: возвращает точку в координатах view
    var onTap: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(session: session)
        view.onTap = onTap
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.onTap = onTap
    }
}

// UIView с AVCaptureVideoPreviewLayer
final class PreviewUIView: UIView {

    var onTap: ((CGPoint) -> Void)?

    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds

        // iOS 17+: выставляем портретный угол поворота для превью
        // Без этого слой может оставаться чёрным (нет дефолтного ориентирования)
        if let connection = previewLayer.connection {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        let point = gr.location(in: self)
        onTap?(point)
    }

    // Для преобразования координат tap → координаты устройства
    var capturePreviewLayer: AVCaptureVideoPreviewLayer { previewLayer }
}

// MARK: - Анимация фокусировочного квадрата

struct FocusSquareView: View {
    let point: CGPoint
    @Binding var isVisible: Bool

    @State private var scale: CGFloat = 1.3
    @State private var opacity: Double = 1.0

    var body: some View {
        ZStack {
            // Внешний квадрат — золотой, тонкий
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: 72, height: 72)

            // Угловые маркеры (как на реальных камерах)
            FocusCorners()
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: 72, height: 72)
        }
        .scaleEffect(scale)
        .opacity(opacity)
        .position(point)
        .onAppear {
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                scale = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.4)) {
                    opacity = 0.0
                    isVisible = false
                }
            }
        }
    }
}

// Четыре угловых маркера фокусировки
struct FocusCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len: CGFloat = 14
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            // Верхний левый
            (CGPoint(x: rect.minX + len, y: rect.minY),
             CGPoint(x: rect.minX,       y: rect.minY),
             CGPoint(x: rect.minX,       y: rect.minY + len)),
            // Верхний правый
            (CGPoint(x: rect.maxX - len, y: rect.minY),
             CGPoint(x: rect.maxX,       y: rect.minY),
             CGPoint(x: rect.maxX,       y: rect.minY + len)),
            // Нижний левый
            (CGPoint(x: rect.minX + len, y: rect.maxY),
             CGPoint(x: rect.minX,       y: rect.maxY),
             CGPoint(x: rect.minX,       y: rect.maxY - len)),
            // Нижний правый
            (CGPoint(x: rect.maxX - len, y: rect.maxY),
             CGPoint(x: rect.maxX,       y: rect.maxY),
             CGPoint(x: rect.maxX,       y: rect.maxY - len))
        ]
        for (a, b, c) in corners {
            p.move(to: a)
            p.addLine(to: b)
            p.addLine(to: c)
        }
        return p
    }
}
