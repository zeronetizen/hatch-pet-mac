import AppKit
import AVFoundation
import MetalKit

/// 悬浮窗内容视图的统一协议：AppDelegate 通过它挂拖动结束回调（保存窗口位置）。
protocol PetContentView: AnyObject {
    var dragger: WindowDragger { get }
}

/// 在视图上实现鼠标拖动移动窗口（NSPanel 的 isMovableByWindowBackground
/// 对 MTKView 内容不可靠，所以手动处理）：
/// mouseDown 记录鼠标屏幕坐标与窗口原点，mouseDragged 移窗，
/// 位移小于 3pt 的抬手算点击——本步仅记日志、预留不处理。
final class WindowDragger {
    private var startMouse: NSPoint = .zero
    private var startOrigin: NSPoint = .zero
    private var dragging = false

    var onDragEnd: (() -> Void)?

    func mouseDown(in view: NSView) {
        guard let window = view.window else { return }
        startMouse = NSEvent.mouseLocation
        startOrigin = window.frame.origin
        dragging = true
        PetLog.d("拖动开始 origin=\(startOrigin)")
    }

    func mouseDragged(in view: NSView) {
        guard dragging, let window = view.window else { return }
        let now = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: startOrigin.x + now.x - startMouse.x,
                                      y: startOrigin.y + now.y - startMouse.y))
    }

    func mouseUp(in view: NSView) {
        guard dragging else { return }
        dragging = false
        let now = NSEvent.mouseLocation
        let dist = hypot(now.x - startMouse.x, now.y - startMouse.y)
        if dist < 3 {
            PetLog.d("悬浮窗点击（位移 \(String(format: "%.1f", dist))pt < 3，预留不处理）")
        } else {
            PetLog.d("悬浮窗拖动结束 origin=\(view.window?.frame.origin ?? .zero) 位移=\(String(format: "%.1f", dist))pt")
            onDragEnd?()
        }
    }
}

/// Metal 渲染模式的内容视图（MTKView），自带拖动处理。
final class PetMetalView: MTKView, PetContentView {
    let dragger = WindowDragger()

    override func mouseDown(with event: NSEvent) { dragger.mouseDown(in: self) }
    override func mouseDragged(with event: NSEvent) { dragger.mouseDragged(in: self) }
    override func mouseUp(with event: NSEvent) { dragger.mouseUp(in: self) }
}

/// Metal 不可用时的回退内容视图：普通 NSView + AVPlayerLayer（接受白底、保功能）。
final class PetFallbackView: NSView, PetContentView {
    let dragger = WindowDragger()
    private(set) var playerLayer: AVPlayerLayer?

    func attachPlayerLayer(_ layer: AVPlayerLayer) {
        wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        playerLayer = layer
        PetLog.d("回退视图已挂 AVPlayerLayer frame=\(bounds)")
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }

    override func mouseDown(with event: NSEvent) { dragger.mouseDown(in: self) }
    override func mouseDragged(with event: NSEvent) { dragger.mouseDragged(in: self) }
    override func mouseUp(with event: NSEvent) { dragger.mouseUp(in: self) }
}
