import AppKit
import SwiftUI

struct AppIcon: View {
    private static let profile: [CGFloat] = [0.34, 0.62, 1.0, 0.62, 0.34]

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            let tile = side * 824 / 1024
            let shape = RoundedRectangle(cornerRadius: tile * 185 / 824, style: .continuous)
            shape
                .fill(LinearGradient(colors: [Color(red: 0.08, green: 0.08, blue: 0.11),
                                              Color(red: 0.02, green: 0.02, blue: 0.035)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    ZStack {
                        bloom(Color(red: 0.35, green: 0.95, blue: 0.88), at: .init(x: 0.14, y: 0.08), side: tile, spread: 0.72)
                        bloom(Color(red: 0.95, green: 0.35, blue: 0.72), at: .init(x: 0.86, y: 0.14), side: tile, spread: 0.62)
                        bloom(Color(red: 0.42, green: 0.45, blue: 1.0), at: .init(x: 0.30, y: 0.92), side: tile, spread: 0.80)
                    }
                    .blur(radius: tile * 0.06)
                    .blendMode(.plusLighter)
                    .clipShape(shape)
                }
                .overlay {
                    shape.fill(LinearGradient(colors: [.white.opacity(0.26), .clear],
                                              startPoint: .top, endPoint: .init(x: 0.5, y: 0.34)))
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.06)],
                                                      startPoint: .top, endPoint: .bottom),
                                       lineWidth: tile * 5 / 824)
                }
                .overlay { meter(side: tile) }
                .frame(width: tile, height: tile)
                .shadow(color: .black.opacity(0.35), radius: tile * 0.05, y: tile * 0.025)
                .frame(width: side, height: side)
        }
    }

    private func bloom(_ colour: Color, at point: UnitPoint, side: CGFloat, spread: CGFloat) -> some View {
        RadialGradient(colors: [colour.opacity(0.62), colour.opacity(0.12), .clear],
                       center: point, startRadius: 0, endRadius: side * spread)
    }

    private func meter(side: CGFloat) -> some View {
        let width = side * 0.072
        return HStack(spacing: width * 0.95) {
            ForEach(Self.profile.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: width, height: side * 0.42 * Self.profile[index])
            }
        }
        .shadow(color: .black.opacity(0.3), radius: side * 0.02, y: side * 0.008)
    }
}

@MainActor
func png(side: CGFloat) -> Data {
    let renderer = ImageRenderer(content: AppIcon().frame(width: side, height: side))
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not render the icon at \(Int(side)) pt\n".utf8))
        exit(1)
    }
    return data
}

MainActor.assumeIsolated {
    let here = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
    let iconset = here.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for point in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
            try! png(side: CGFloat(point * scale)).write(to: iconset.appendingPathComponent(name))
        }
    }
    let convert = Process()
    convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    convert.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
    try! convert.run()
    convert.waitUntilExit()
    try? FileManager.default.removeItem(at: iconset)
    exit(convert.terminationStatus)
}

