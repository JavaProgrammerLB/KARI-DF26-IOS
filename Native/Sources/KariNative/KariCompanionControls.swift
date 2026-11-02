import SwiftUI

struct KariCompanionControls: View {
    @ObservedObject private var localization = KariLocalization.shared
    @ObservedObject var app: KariAppModel
    @ObservedObject var live: KariLiveService
    @ObservedObject var camera: KariCamera
    @ObservedObject var settings: KariSettings
    @ObservedObject var bodyService: KariBluetooth
    let landscape: Bool
    @State private var text = ""
    @State private var attachImage = false
    private let accent = Color(red: 0.65, green: 0.91, blue: 0.95)
    var body: some View {
        VStack(spacing: landscape ? 8 : 14) {
            if !landscape {
                HStack {
                    Label(bodyService.isConnected ? bodyService.connectedName : L("未连接身体"), systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if live.connected { Label(L("AI 在线"), systemImage: "waveform") }
                    if camera.running { KariCameraPreview(camera: camera).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel(L("摄像头实时预览")) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if !app.liveFailure.isEmpty {
                Label(L("陪伴继续，实时 AI 暂不可用"), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).accessibilityIdentifier("liveFailureTitle")
            }
            Text(LM(!app.liveFailure.isEmpty ? app.liveFailure : !camera.message.isEmpty ? camera.message : app.notice))
                .font(.footnote).foregroundStyle(app.liveFailure.isEmpty ? Color.secondary : Color.orange).lineLimit(app.liveFailure.isEmpty && landscape ? 1 : 3)
                .frame(maxWidth: .infinity).accessibilityIdentifier("runtimeNotice")
            HStack(spacing: landscape ? 12 : 18) {
                control(app.zhipuVoice && !live.uploadsVideo ? L("开启实时画面") : (app.cameraEnabled ? L("关闭相机") : L("开启相机")), icon: camera.running ? "video.fill" : "video.slash", action: app.toggleCamera)
                control(L("切换镜头"), icon: "arrow.triangle.2.circlepath.camera", action: app.switchCamera)
                control(L("测试声音"), icon: "speaker.wave.2", action: app.testSound)
                if app.isActive {
                    control(L("允许陪伴时的身体动作"), icon: settings.motionEnabled ? "figure.walk.circle.fill" : "figure.walk.circle") { app.setCompanionMotionEnabled(!settings.motionEnabled) }
                        .disabled(!bodyService.isConnected).foregroundStyle(settings.motionEnabled ? accent : .secondary)
                        .accessibilityValue(settings.motionEnabled ? L("开启") : L("关闭"))
                        .accessibilityIdentifier("companionMotionEnabled")
                }
                if app.isActive { control(L(app.liveFailure.isEmpty ? "恢复采集" : "重试实时 AI"), icon: "arrow.clockwise", action: app.recoverCapture).accessibilityIdentifier("retryLiveConnection") }
            }.disabled(app.isBusy)
            if !landscape && !app.isActive {
                HStack(spacing: 12) {
                    Button(L("动作测试"), action: app.testMotion).disabled(!bodyService.isConnected || app.isBusy)
                    Spacer()
                    Button(L("AI 测试"), action: app.testAI).disabled(app.isBusy)
                }.font(.subheadline).padding(.horizontal, 16).frame(height: 40)
            }
            if app.isActive && !settings.configuration.isLive {
                HStack {
                    Button { attachImage.toggle() } label: {
                        Image(systemName: attachImage ? "photo.fill" : "photo").foregroundStyle(attachImage ? accent : .secondary).frame(width: 44, height: 44)
                    }.disabled(!camera.running).accessibilityLabel(attachImage ? L("取消附加画面") : L("附加画面，需要视觉模型"))
                    TextField(L("和 KARI 说点什么…"), text: $text).textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit(send)
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel(L("发送消息"))
                }
                if !app.textReply.isEmpty { Text(app.textReply).font(.subheadline).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading) }
            }
            KariMemorySources(hits: app.memory.hits)
            if !landscape {
            Button(action: primary) {
                Label(app.phase == .stopping ? L("正在结束…") : app.phase == .testing ? L("取消测试") : app.phase == .starting ? L("取消连接") : app.isActive ? L("退出陪伴") : L("开始陪伴"), systemImage: app.phase == .idle ? "play.fill" : "stop.fill")
                    .font(.headline).frame(maxWidth: landscape ? 220 : .infinity).frame(height: 52)
                    .foregroundStyle(app.phase == .idle ? Color.black : Color.white)
                    .background(app.phase == .idle ? accent : Color.white.opacity(0.12), in: Capsule())
            }.buttonStyle(.plain).disabled(app.phase == .stopping).accessibilityIdentifier("startExperience")
            }
        }
        .padding(landscape ? 10 : 18)
        .modifier(KariFloatingSurface(radius: 26))
    }
    private func control(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) { Image(systemName: icon).font(.title3).frame(height: 30); if !landscape { Text(title).font(.caption2) } }
                .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
    private func primary() { if app.phase == .idle { app.start() } else { Task { await app.stop() } } }
    private func send() { if app.sendText(text, includeImage: attachImage && camera.running) { text = ""; attachImage = false } }
}
