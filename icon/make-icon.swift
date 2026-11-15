// Renders the app icon (a lime cursor bot: block cursor + pixel eyes + legs, typing ">_") to icon/AppIcon.png at 1024px.
// Run by build.sh only when AppIcon.icns is missing: swift icon/make-icon.swift <out.png>
import SwiftUI
import AppKit

func rgb(_ h: Int) -> Color { Color(red: Double(h >> 16 & 255) / 255, green: Double(h >> 8 & 255) / 255, blue: Double(h & 255) / 255) }
let ink = rgb(0x0b0b0b)
let lime = rgb(0xd7ff3f)

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS tile: 824px rounded square inside the 1024 canvas (Apple's grid)
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [rgb(0x1c1c1c), rgb(0x050505)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            // ground shadow
            Ellipse().fill(Color.black.opacity(0.6)).frame(width: 300, height: 40).offset(x: -40, y: 290)
            // legs
            HStack(spacing: 96) {
                Capsule().fill(lime).frame(width: 40, height: 90)
                Capsule().fill(lime).frame(width: 40, height: 90).offset(y: -18)
            }
            .offset(x: -40, y: 225)
            // the cursor block
            ZStack {
                RoundedRectangle(cornerRadius: 44, style: .continuous).fill(lime)
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
                HStack(spacing: 78) {
                    RoundedRectangle(cornerRadius: 12).fill(ink).frame(width: 52, height: 70)
                    RoundedRectangle(cornerRadius: 12).fill(ink).frame(width: 52, height: 70)
                }
                .offset(y: -50)
                Rectangle().fill(ink).frame(width: 110, height: 24).offset(x: -40, y: 90)  // the "_" prompt line
            }
            .frame(width: 320, height: 420)
            .offset(x: -40, y: -20)
            // typed characters drifting out, top-right
            Text(">_").font(.system(size: 104, weight: .heavy, design: .monospaced)).foregroundStyle(lime)
                .offset(x: 230, y: -190)
            Text("{}").font(.system(size: 64, weight: .heavy, design: .monospaced)).foregroundStyle(lime.opacity(0.45))
                .offset(x: 270, y: -310)
        }
        .frame(width: 1024, height: 1024)
    }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
await MainActor.run {
    let r = ImageRenderer(content: Icon())
    r.scale = 1
    guard let cg = r.cgImage else { fatalError("render failed") }
    let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: out))
}
