// GalleryView.swift — галерея снятых фотографий
// Сетка миниатюр + детальный просмотр с метаданными обработки

import SwiftUI

struct GalleryView: View {

    @EnvironmentObject var gallery: GalleryStore
    @Environment(\.dismiss) var dismiss

    @State private var selectedPhoto: PhotoResult? = nil
    @State private var showDetail     = false

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if gallery.recentPhotos.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(gallery.recentPhotos) { photo in
                            GalleryCell(photo: photo)
                                .onTapGesture {
                                    selectedPhoto = photo
                                    showDetail    = true
                                }
                        }
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Галерея")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(gallery.recentPhotos.count) фото")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $selectedPhoto) { photo in
            PhotoDetailView(photo: photo)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundStyle(.white.opacity(0.2))
            Text("Нет фотографий")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.4))
            Text("Снятые фото появятся здесь")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 120)
    }
}

// MARK: - Ячейка галереи

struct GalleryCell: View {
    let photo: PhotoResult

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: photo.thumbnailImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.width)
                    .clipped()

                // Бейджи режима
                HStack(spacing: 4) {
                    if photo.processingInfo.nightModeUsed {
                        Badge(symbol: "moon.fill", color: .blue)
                    }
                    if photo.processingInfo.hdrUsed {
                        Badge(symbol: "sun.max.fill", color: .orange)
                    }
                    if photo.processingInfo.alignedFrameCount > 1 {
                        Badge(text: "\(photo.processingInfo.alignedFrameCount)×")
                    }
                }
                .padding(4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct Badge: View {
    var symbol: String? = nil
    var text:   String? = nil
    var color:  Color   = .white

    var body: some View {
        Group {
            if let sym = symbol {
                Image(systemName: sym)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(color)
            } else if let t = text {
                Text(t)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.6)))
    }
}

// MARK: - Детальный просмотр фото

struct PhotoDetailView: View {

    let photo: PhotoResult
    @Environment(\.dismiss) var dismiss
    @State private var showInfo = false
    @State private var scale:     CGFloat = 1.0
    @State private var offset: CGSize = .zero

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                // Фото с пинч-зумом
                Image(uiImage: photo.finalImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in scale = max(1.0, v) }
                            .onEnded   { v in
                                if scale < 1.0 {
                                    withAnimation { scale = 1.0; offset = .zero }
                                }
                            }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { v in if scale > 1.0 { offset = v.translation } }
                            .onEnded   { _ in if scale <= 1.0 { withAnimation { offset = .zero } } }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.3)) {
                            scale  = scale > 1.0 ? 1.0 : 2.0
                            offset = .zero
                        }
                    }

                // Панель информации снизу
                if showInfo {
                    VStack {
                        Spacer()
                        InfoPanel(photo: photo)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        // Кнопка информации
                        Button(action: { withAnimation(.spring(duration: 0.35)) { showInfo.toggle() } }) {
                            Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                                .foregroundStyle(.white)
                        }
                        // Поделиться
                        ShareLink(item: Image(uiImage: photo.finalImage), preview: SharePreview("LCAM Photo", image: Image(uiImage: photo.finalImage))) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Панель с информацией об обработке

struct InfoPanel: View {
    let photo: PhotoResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Информация о снимке")
                .font(.headline)
                .foregroundStyle(.white)

            Divider().background(.white.opacity(0.2))

            // Параметры съёмки
            HStack {
                InfoRow(label: "ISO",       value: photo.exif.isoDisplayString)
                InfoRow(label: "Выдержка",  value: photo.exif.shutterSpeedDisplayString)
                InfoRow(label: "Диафрагма", value: photo.exif.apertureDisplayString)
            }

            Divider().background(.white.opacity(0.2))

            // Параметры обработки
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    InfoRow(label: "Кадров захвачено", value: "\(photo.processingInfo.capturedFrameCount)")
                    InfoRow(label: "Выровнено",         value: "\(photo.processingInfo.alignedFrameCount)")
                    InfoRow(label: "Отброшено",         value: "\(photo.processingInfo.rejectedFrameCount)")
                }

                HStack {
                    InfoRow(
                        label: "Снижение шума",
                        value: String(format: "%.1f×", photo.processingInfo.noiseReductionGain)
                    )
                    InfoRow(
                        label: "Время обработки",
                        value: String(format: "%.0f мс", photo.processingInfo.processingTimeMs)
                    )
                }

                // Список алгоритмов
                FlowLayout(items: photo.processingInfo.algorithmsApplied) { algo in
                    Text(algo)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.15)))
                }
            }

            Text(photo.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 40)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - FlowLayout для тегов

struct FlowLayout<Item: Hashable, Content: View>: View {
    let items:   [Item]
    let content: (Item) -> Content

    @State private var totalHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            self.generateContent(in: geo)
        }
        .frame(height: totalHeight)
    }

    private func generateContent(in geo: GeometryProxy) -> some View {
        var x: CGFloat = 0
        var y: CGFloat = 0
        return ZStack(alignment: .topLeading) {
            ForEach(items, id: \.self) { item in
                content(item)
                    .padding(.all, 2)
                    .alignmentGuide(.leading) { d in
                        if abs(x - d.width) > geo.size.width {
                            x = 0; y -= d.height
                        }
                        let result = x
                        x -= d.width
                        if item == items.last { x = 0; y = 0 }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = y
                        if item == items.last { y = 0 }
                        return result
                    }
            }
        }
        .background(viewHeightReader($totalHeight))
    }

    private func viewHeightReader(_ height: Binding<CGFloat>) -> some View {
        GeometryReader { geo in
            Color.clear.onAppear { height.wrappedValue = geo.size.height }
        }
    }
}
