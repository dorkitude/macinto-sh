#if DEBUG
import AppKit
import SwiftUI

/// Dev builds only: `Macinto --snapshot STATE OUT.png` renders one UI state offscreen to a 2x PNG
/// and exits. No window, no Dock or menu bar item, no socket, no permission checks or prompts.
/// Permission and enabled state are faked for the render only. Compiled out of release builds.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let argv = CommandLine.arguments
        guard let i = argv.firstIndex(of: "--snapshot") else { return }
        guard i + 2 < argv.count, let preview = AppState.Preview(rawValue: argv[i + 1]) else {
            FileHandle.standardError.write(Data("usage: --snapshot STATE OUT.png; STATE is one of \(AppState.Preview.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
            exit(2)
        }
        let out = URL(fileURLWithPath: argv[i + 2])
        NSApplication.shared.setActivationPolicy(.prohibited)
        PulsingApple.animates = false
        Paths.uiName = "Macinto.sh"
        let state = AppState.shared
        state.startPreview(preview)
        let view = MenuView(state: state, installCLI: {}, openLog: {}, relaunch: {}, quit: {})
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: cg.width / 2, height: cg.height / 2)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: out)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
        print("\(out.path) \(cg.width)x\(cg.height)")
        exit(0)
    }
}
#endif
