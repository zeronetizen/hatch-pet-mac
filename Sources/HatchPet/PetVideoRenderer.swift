import AppKit
import AVFoundation
import MetalKit
import QuartzCore

/// 运行时亮度抠像着色器（与 Android v0.2 同参数，已在抽帧上验证）：
/// 源视频无 alpha、白底烤在画面里；alpha = smoothstep(0.031, 0.149, 1 - min(r,g,b))，
/// 输出预乘 alpha。着色器源码内嵌字符串、运行时 makeLibrary(source:) 编译——
/// SwiftPM 可执行文件加载独立 .metal 资源麻烦，定版不用 .metal 文件。
private let petShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut petVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    float2 uvs[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texCoord = uvs[vid];
    return out;
}

fragment float4 petFragment(VertexOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 c = tex.sample(s, in.texCoord);
    float d = 1.0 - min(c.r, min(c.g, c.b));
    float a = smoothstep(0.031, 0.149, d);
    if (a <= 0.001) discard_fragment();
    return float4(c.rgb * a, a);
}
"""

/// 视频渲染器：AVPlayer 解码，AVPlayerItemVideoOutput 取 CVPixelBuffer，
/// 经 CVMetalTextureCache 喂给 MTKView 做着色器抠像（视图与窗口全透明）。
/// Metal 初始化或着色器编译失败时回退到 AVPlayerLayer 普通显示（白底、保功能）。
/// 循环态：播到结尾 seek 回 0 重播（不用 AVPlayerLooper——它会复制 item，
/// AVPlayerItemVideoOutput 挂在模板 item 上不可靠）；一次性态：结尾回调状态机回落。
final class PetVideoRenderer: NSObject, MTKViewDelegate {
    enum Mode {
        case metal
        case layerFallback
    }

    private struct MetalContext {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let textureCache: CVMetalTextureCache
        let view: PetMetalView
    }

    private(set) var mode: Mode
    let contentView: NSView

    private let player = AVPlayer()
    private let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    private var currentItem: AVPlayerItem?
    private var currentState: PetState?
    private var itemStatusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var pausedBySleep = false

    private let metalContext: MetalContext?
    private var playerLayer: AVPlayerLayer?
    /// 持有当前帧的 CVMetalTexture 到下一帧，避免渲染完成前被释放
    private var retainedTexture: CVMetalTexture?

    /// 一次性状态播完时回调（由 AppDelegate 接到 StateMachine.handlePlaybackFinished）
    var onPlayToEnd: (() -> Void)?

    override init() {
        if let ctx = Self.buildMetalContext() {
            mode = .metal
            metalContext = ctx
            contentView = ctx.view
        } else {
            mode = .layerFallback
            metalContext = nil
            contentView = PetFallbackView()
        }
        super.init()

        player.actionAtItemEnd = .pause
        if mode == .metal, let ctx = metalContext {
            ctx.view.delegate = self
            PetLog.d("渲染器就绪 mode=metal")
        } else if let fallbackView = contentView as? PetFallbackView {
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resize
            fallbackView.attachPlayerLayer(layer)
            playerLayer = layer
            PetLog.d("渲染器就绪 mode=layerFallback（Metal 不可用，显示将带白底）")
        }
    }

    // MARK: - Metal 初始化（静态，避免在 super.init 前调用实例方法）

    private static func buildMetalContext() -> MetalContext? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            PetLog.d("Metal 初始化失败：MTLCreateSystemDefaultDevice 返回 nil")
            return nil
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: petShaderSource, options: nil)
            PetLog.d("Metal 着色器编译成功 device=\(device.name)")
        } catch {
            PetLog.d("Metal 着色器编译失败：\(error.localizedDescription)")
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "petVertex"),
              let fragmentFn = library.makeFunction(name: "petFragment") else {
            PetLog.d("Metal 初始化失败：着色器函数 petVertex/petFragment 缺失")
            return nil
        }
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            PetLog.d("Metal 管线创建失败：\(error.localizedDescription)")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            PetLog.d("Metal 初始化失败：makeCommandQueue 返回 nil")
            return nil
        }
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let textureCache = cache else {
            PetLog.d("Metal 初始化失败：CVMetalTextureCacheCreate status=\(cacheStatus)")
            return nil
        }
        let view = PetMetalView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.preferredFramesPerSecond = 60
        PetLog.d("Metal 初始化成功 device=\(device.name)")
        return MetalContext(device: device, queue: queue, pipeline: pipeline,
                            textureCache: textureCache, view: view)
    }

    // MARK: - 播放控制

    func play(state: PetState) {
        currentState = state
        guard let url = ResourceLocator.videoURL(for: state) else {
            PetLog.d("播放中止：资源缺失 state=\(state.rawValue)")
            return
        }
        if let old = currentItem {
            old.remove(videoOutput)
        }
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        let item = AVPlayerItem(url: url)
        if mode == .metal {
            item.add(videoOutput)
        }
        currentItem = item
        itemStatusObserver = item.observe(\.status, options: [.new]) { item, _ in
            switch item.status {
            case .readyToPlay:
                PetLog.d("播放器 item ready state=\(state.rawValue) duration=\(String(format: "%.2f", CMTimeGetSeconds(item.duration)))s")
            case .failed:
                PetLog.d("播放器 item 失败 state=\(state.rawValue) error=\(item.error?.localizedDescription ?? "unknown")")
            default:
                break
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.handleItemEnd()
        }
        player.replaceCurrentItem(with: item)
        if !pausedBySleep {
            player.play()
        }
        PetLog.d("播放开始 state=\(state.rawValue)（\(state.label)）oneShot=\(state.oneShot) mode=\(mode) file=\(url.lastPathComponent) pausedBySleep=\(pausedBySleep)")
    }

    private func handleItemEnd() {
        guard let state = currentState else { return }
        if state.oneShot {
            PetLog.d("播放到结尾（一次性）state=\(state.rawValue)，通知状态机回落")
            onPlayToEnd?()
        } else {
            PetLog.d("播放到结尾（循环）state=\(state.rawValue)，seek 回 0 重播")
            player.seek(to: .zero) { [weak self] finished in
                guard let self else { return }
                PetLog.d("循环重播 seek 完成 state=\(state.rawValue) finished=\(finished)")
                if !self.pausedBySleep {
                    self.player.play()
                }
            }
        }
    }

    func pauseForSleep() {
        pausedBySleep = true
        player.pause()
        PetLog.d("播放暂停（睡眠/锁屏）state=\(currentState?.rawValue ?? "nil")")
    }

    func resumeFromSleep() {
        pausedBySleep = false
        player.play()
        PetLog.d("播放恢复（唤醒/解锁）state=\(currentState?.rawValue ?? "nil")")
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        PetLog.d("drawable 尺寸变化 size=\(size)")
    }

    func draw(in view: MTKView) {
        guard mode == .metal, let ctx = metalContext,
              let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              player.currentItem != nil else { return }
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid,
              videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
              let texture = makeTexture(from: pixelBuffer, cache: ctx.textureCache) else { return }
        guard let commandBuffer = ctx.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(ctx.pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        CVMetalTextureCacheFlush(ctx.textureCache, 0)
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            PetLog.d("CVMetalTexture 创建失败 status=\(status) \(width)x\(height)")
            return nil
        }
        retainedTexture = cvTexture
        return texture
    }
}
