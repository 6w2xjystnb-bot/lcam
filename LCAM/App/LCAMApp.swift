// LCAMApp.swift — точка входа приложения

import SwiftUI

@main
struct LCAMApp: App {

    // Shared объекты, живущие всё время работы приложения
    @StateObject private var settings = CameraSettings()
    @StateObject private var pipeline = PostProcessingPipeline()
    @StateObject private var gallery  = GalleryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(pipeline)
                .environmentObject(gallery)
                // Скрываем стандартный статус-бар — UI сам рисует инфо
                .statusBarHidden(true)
                .preferredColorScheme(.dark)   // камера всегда в тёмной теме
                .onAppear {
                    settings.loadPersisted()
                }
        }
    }
}

// ContentView — просто роутер, показывает CameraView
struct ContentView: View {
    @EnvironmentObject var settings: CameraSettings

    var body: some View {
        CameraView()
            .ignoresSafeArea()
    }
}

// GalleryStore — хранилище результатов съёмки в памяти (и обёртка над PhotoKit)
@MainActor
final class GalleryStore: ObservableObject {
    @Published var recentPhotos: [PhotoResult] = []

    func add(_ photo: PhotoResult) {
        recentPhotos.insert(photo, at: 0)
        // Ограничиваем в памяти 50 снимками (остальные — в Photos)
        if recentPhotos.count > 50 {
            recentPhotos = Array(recentPhotos.prefix(50))
        }
    }
}
