// ControlsView.swift — нижняя панель управления (Liquid Glass iOS 26)
// Кнопка затвора, выбор режима, галерея, переключение камеры

import SwiftUI

struct ControlsView: View {

    @EnvironmentObject var settings: CameraSettings
    @EnvironmentObject var gallery:  GalleryStore

    let camera:   CameraManager
    let onGallery: () -> Void

    // Анимация нажатия затвора
    @State private var shutterPressed  = false
    @State private var captureFlash    = false

    // Жест зума
    @State private var baseZoom: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            // --- Слайдер экспозиции ---
            ExposureSlider(value: $settings.exposureBias)
                .padding(.horizontal, 40)
                .padding(.bottom, 12)

            // --- Выбор режима ---
            ModeSelector(selected: $settings.captureMode)
                .padding(.bottom, 16)

            // --- Главная строка: галерея | затвор | смена камеры ---
            HStack(alignment: .center, spacing: 0) {

                // Миниатюра последнего фото → открывает галерею
                Button(action: onGallery) {
                    Group {
                        if let last = gallery.recentPhotos.first {
                            Image(uiImage: last.thumbnailImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.15))
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundStyle(.white.opacity(0.5))
                                )
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
                }
                .frame(maxWidth: .infinity)

                // Кнопка затвора
                ShutterButton(
                    isCapturing: camera.isCapturing,
                    progress:    camera.captureProgress,
                    mode:        settings.captureMode,
                    onPress: {
                        triggerCapture()
                    }
                )
                .frame(maxWidth: .infinity)

                // Смена фронт/тыл
                Button(action: { camera.switchCamera() }) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 56, height: 56)
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            // --- Кнопки зума ---
            ZoomStrip(
                available: camera.availableZoomStops,
                current:   camera.zoomFactor,
                baseZoom:  camera.baseZoomFactor
            ) { factor in
                camera.setZoom(factor)
            }
            .padding(.bottom, 20)
        }
        .background(
            // Жидкое стекло снизу — iOS 26 glass effect + фолбэк
            LiquidGlassBackground()
        )
        // Вспышка экрана при съёмке
        .overlay(
            captureFlash
                ? Color.white.opacity(0.6).ignoresSafeArea()
                : nil
        )
    }

    private func triggerCapture() {
        guard !camera.isCapturing else { return }

        // Тактильный отклик
        let impact = UIImpactFeedbackGenerator(style: .heavy)
        impact.impactOccurred()

        // Вспышка экрана
        withAnimation(.easeIn(duration: 0.05)) { captureFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.2)) { captureFlash = false }
        }

        camera.capturePhoto()
    }
}

// MARK: - Кнопка затвора

struct ShutterButton: View {
    let isCapturing: Bool
    let progress:    Float
    let mode:        CaptureMode
    let onPress:     () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onPress) {
            ZStack {
                // Внешнее кольцо
                Circle()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 80, height: 80)

                // Прогресс бёрста
                if isCapturing {
                    Circle()
                        .trim(from: 0, to: CGFloat(progress))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: progress)
                }

                // Внутренний диск — цвет меняется по режиму
                Circle()
                    .fill(innerColor)
                    .frame(width: 64, height: 64)
                    .scaleEffect(isPressed ? 0.88 : 1.0)
                    .animation(.spring(duration: 0.15, bounce: 0.3), value: isPressed)

                // Иконка для видео
                if mode == .video {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .buttonStyle(PressButtonStyle(isPressed: $isPressed))
        .disabled(isCapturing && mode != .video)
    }

    private var innerColor: Color {
        switch mode {
        case .video:   return .red
        case .night:   return Color(red: 0.2, green: 0.2, blue: 0.6)
        default:       return .white
        }
    }
}

// Стиль кнопки с отслеживанием нажатия
struct PressButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, v in isPressed = v }
    }
}

// MARK: - Переключатель режимов (горизонтальный скролл)

struct ModeSelector: View {
    @Binding var selected: CaptureMode

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(CaptureMode.allCases) { mode in
                    ModeTab(mode: mode, isSelected: selected == mode)
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                                selected = mode
                            }
                            let sel = UISelectionFeedbackGenerator()
                            sel.selectionChanged()
                        }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

struct ModeTab: View {
    let mode:       CaptureMode
    let isSelected: Bool

    var body: some View {
        Text(mode.rawValue)
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .black : .white.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? .white : .clear)
                    .animation(.spring(duration: 0.3), value: isSelected)
            )
    }
}

// MARK: - Полоска зума

struct ZoomStrip: View {
    let available: [CGFloat]
    let current:   CGFloat
    let baseZoom:  CGFloat   // зум-фактор устройства для оптического 1×
    let onSelect:  (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(available, id: \.self) { stop in
                let isActive = abs(current - stop) < 0.3
                Button(action: { onSelect(stop) }) {
                    ZStack {
                        Circle()
                            .fill(isActive ? Color.white.opacity(0.25) : Color.black.opacity(0.3))
                            .frame(width: isActive ? 44 : 38, height: isActive ? 44 : 38)
                        Text(relativeLabel(for: stop))
                            .font(.system(size: isActive ? 15 : 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .animation(.spring(duration: 0.25), value: isActive)
                }
            }
        }
    }

    /// Переводим координату устройства → человеческий множитель (0.5×, 1×, 3×…)
    private func relativeLabel(for stop: CGFloat) -> String {
        let rel = stop / max(baseZoom, 1e-3)
        if rel < 1.0 {
            return String(format: "%.1f×", rel)
        } else {
            return "\(Int(rel.rounded()))×"
        }
    }
}

// MARK: - Слайдер экспозиции

struct ExposureSlider: View {
    @Binding var value: Float  // [-3..+3] EV

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min")
                .foregroundStyle(.white.opacity(0.7))
                .font(.system(size: 14))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Трек
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 3)

                    // Центральная отметка
                    Rectangle()
                        .fill(Color.yellow.opacity(0.6))
                        .frame(width: 1, height: 8)
                        .offset(x: geo.size.width / 2)

                    // Заливка
                    Capsule()
                        .fill(Color.yellow.opacity(0.7))
                        .frame(
                            width: abs(CGFloat(value) / 3.0) * geo.size.width / 2,
                            height: 3
                        )
                        .offset(x: value >= 0
                                ? geo.size.width / 2
                                : geo.size.width / 2 - abs(CGFloat(value) / 3.0) * geo.size.width / 2
                        )

                    // Ручка
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .offset(x: ((CGFloat(value) / 3.0 + 1.0) / 2.0) * geo.size.width - 9)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let normalized = Float(v.location.x / geo.size.width) * 2 - 1
                            value = max(-3, min(3, normalized * 3))
                        }
                )
            }
            .frame(height: 18)

            Image(systemName: "sun.max")
                .foregroundStyle(.white.opacity(0.7))
                .font(.system(size: 14))

            // Текущее значение
            Text(value >= 0 ? "+\(String(format: "%.1f", value))" : String(format: "%.1f", value))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.yellow)
                .frame(width: 36)
        }
    }
}

// MARK: - Фон Liquid Glass (iOS 26 + фолбэк)

struct LiquidGlassBackground: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.black.opacity(0.6), .black.opacity(0.3)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
            )
    }
}
