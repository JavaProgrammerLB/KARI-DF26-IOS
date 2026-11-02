import SwiftUI
import Combine

@MainActor public func makeKariRootController() -> UIViewController {
    let arguments = ProcessInfo.processInfo.arguments
    let testing = arguments.contains("--ui-testing")
    let simulate = testing && arguments.contains("--ui-testing-live-failure")
    let ready = testing && arguments.contains("--ui-testing-live-ready")
    let listening = testing && arguments.contains("--ui-testing-wake-listening")
    let app = KariAppModel(liveStarter: simulate ? { _ in throw KariError.message("Google 实时 AI 不支持当前网络出口所在地区；请核对服务支持地区或选择其他 AI 服务。") } : ready ? { _ in } : nil)
    if simulate || ready || listening { try? app.settings.save(.fresh("gemini"), key: ""); app.cameraEnabled = false }
    if listening { app.companion.wakeSettings.enabled = true }
    return KariHostingController(app: app)
}

// UIKit owns scene rotation; SwiftUI owns presentation and the companion lifecycle.
@MainActor private final class KariHostingController: UIHostingController<KariRootView> {
    private let app: KariAppModel
    private var subscription: AnyCancellable?
    private var companion = false
    init(app: KariAppModel) {
        self.app = app
        super.init(rootView: KariRootView(app: app))
        subscription = app.$phase.map { $0 == .starting || $0 == .active }
            .removeDuplicates().sink { [weak self] companion in
                // @Published emits before the property changes; defer UIKit work.
                DispatchQueue.main.async { self?.setCompanion(companion) }
            }
    }
    @objc required dynamic init?(coder aDecoder: NSCoder) { fatalError("Use init(app:)") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { companion ? .landscape : .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { companion ? .landscapeRight : .portrait }
    override var shouldAutorotate: Bool { true }
    override var prefersStatusBarHidden: Bool { companion }
    override var prefersHomeIndicatorAutoHidden: Bool { companion }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); rotateScene() }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.app.camera.updateOrientation() }
    }
    private func setCompanion(_ value: Bool) {
        companion = value
        setNeedsStatusBarAppearanceUpdate(); setNeedsUpdateOfHomeIndicatorAutoHidden()
        rotateScene()
    }
    private func rotateScene() {
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            guard let scene = viewIfLoaded?.window?.windowScene else { return }
            let requested = companion
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations)) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.companion == requested else { return }
                    self.app.notice = requested ? "请将手机横放以显示眼睛；轻点屏幕可退出陪伴。" : "请将手机竖放以查看设置。"
                }
            }
        } else { UIViewController.attemptRotationToDeviceOrientation() }
    }
}

private enum KariDestination: String, Identifiable {
    case robots, ai, remote
    var id: String { rawValue }
}
private enum KariTab: Int { case robot, personality, memory, settings }

struct KariRootView: View {
    @ObservedObject private var localization = KariLocalization.shared
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var app: KariAppModel
    @State private var tab: KariTab = .robot
    @State private var destination: KariDestination?
    @State private var controlsVisible = false
    @State private var prompted = false
    private var companion: Bool { app.phase == .starting || app.phase == .active || app.phase == .stopping }
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                KariEyesView(face: app.face).ignoresSafeArea().opacity(companion && landscape ? 1 : 0).allowsHitTesting(false).accessibilityHidden(true)
                if companion {
                    Color.clear.contentShape(Rectangle()).onTapGesture { withAnimation { controlsVisible.toggle() } }
                        .accessibilityElement().accessibilityIdentifier("companionSurface").accessibilityLabel(L("陪伴画面，轻点显示退出按钮"))
                        .accessibilityAddTraits(.isButton).accessibilityAction { controlsVisible = true }
                        .accessibilityAction(named: Text(L("退出陪伴"))) { Task { await app.stop() } }
                    if app.camera.running {
                        KariCompanionCameraWindow(camera: app.camera).frame(width: 130, height: 98)
                            .clipShape(RoundedRectangle(cornerRadius: 14)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12).allowsHitTesting(false)
                    }
                    if app.phase == .active && app.settings.configuration.isLive {
                        VStack {
                            Text(app.live.microphone
                                 ? "麦克风\(app.live.inputLevel > 0.08 ? "有声音" : app.live.inputLevel > 0.02 ? "太轻" : "静音") \(Int(app.live.inputLevel * 100)) 上传\(app.live.uploadedAudioFrames) 提交\(app.live.committedTurns)"
                                 : "麦克风未打开")
                                .font(.caption2).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                            if !app.live.serverNote.isEmpty {
                                Text(app.live.serverNote).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(.black.opacity(0.55), in: Capsule())
                            }
                            if !app.live.heard.isEmpty {
                                Text("听到：" + app.live.heard).font(.caption2).foregroundStyle(.white).lineLimit(1)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(.black.opacity(0.55), in: Capsule())
                            }
                            Spacer()
                        }.padding(.top, 8).allowsHitTesting(false)
                    }
                    if controlsVisible || !app.liveFailure.isEmpty || app.wake.phase == .waiting || app.wake.phase == .connecting || app.wake.phase == .suspended || !app.settings.configuration.isLive || app.phase != .active || UIAccessibility.isVoiceOverRunning {
                        activeControls
                        VStack { HStack { Spacer(); KariCompanionStopButton(app: app) }; Spacer() }.padding(12)
                    }
                } else {
                    KariNativeTabs(selection: Binding(get: { tab.rawValue }, set: { tab = KariTab(rawValue: $0) ?? .robot }), session: app.body.management, pages: [
                        AnyView(KariDeviceManagement(robot: app.body, wifi: app.body.wifi, embedded: true, connect: { destination = .robots }, remote: { destination = .remote }, vision: AnyView(KariVisionContent(app: app, features: app.companion, vision: app.companion.vision, camera: app.camera)))),
                        AnyView(KariPersonalityView(features: app.companion)),
                        AnyView(KariMemoryView(app: app, memory: app.memory)),
                        AnyView(KariNativeSettingsPage(app: app, robots: { destination = .robots }, ai: { destination = .ai }))
                    ], language: localization.language, canStart: !app.isBusy, start: { guard !app.body.management.busy, app.body.management.info["ota_mode"] as? Bool != true else { return }; app.start() })
                    .ignoresSafeArea()

                }
            }
            .task(id: controlsVisible && companion && !app.remote.presented) {
                guard controlsVisible, companion, app.liveFailure.isEmpty, !app.remote.presented, app.settings.configuration.isLive, !UIAccessibility.isVoiceOverRunning else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled { withAnimation { controlsVisible = false } }
            }
            .onChange(of: app.phase) { _ in controlsVisible = companion; if companion { destination = nil }; if app.phase == .idle && scenePhase == .active { app.memory.resume(app.settings.configuration) } }
            .onChange(of: app.remote.presented) { if $0 { controlsVisible = true } }
            .onChange(of: geometry.size) { _ in app.camera.updateOrientation(); if app.remote.presented { app.remote.emergencyStop() } }
            .onAppear {
                app.camera.updateOrientation()
                if !ProcessInfo.processInfo.arguments.contains("--ui-testing") && !prompted && !app.body.isConnected { prompted = true; destination = .robots }
            }
        }
        .environment(\.locale, localization.locale).preferredColorScheme(.dark)
        .sheet(item: $destination) { target in
            switch target {
            case .robots: KariRobotList(app: app, bluetooth: app.body)
            case .ai: KariSettingsView(app: app, settings: app.settings)
            case .remote: KariRemoteScreen(remote: app.remote, bluetooth: app.body)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { app.remote.emergencyStop() }
            if phase == .background { app.memory.suspend(); Task { await app.suspendForBackground() } }
            if phase == .active { localization.refreshSystemLanguage(); app.memory.resume(app.settings.configuration) }
        }
    }
    private var activeControls: some View {
        VStack {
            Spacer()
            if app.remote.presented {
                KariRemoteView(remote: app.remote, bluetooth: app.body, compact: true) { app.remote.close() }
            } else {
                HStack {
                    Button { app.remote.open() } label: { Image(systemName: "gamecontroller").frame(width: 48, height: 44) }.accessibilityLabel(L("遥控器")).disabled(!app.body.isConnected || app.isBusy)
                    Button { app.companion.triggerRule() } label: { Image(systemName: "sparkles").frame(width: 44, height: 44) }.accessibilityLabel(L("触发本地规则"))
                    Button { app.companion.think() } label: { Image(systemName: "brain.head.profile").frame(width: 44, height: 44) }.accessibilityLabel(L("主动思考一次"))
                }.padding(.horizontal, 8).modifier(KariFloatingSurface(radius: 22))
                KariWakeControls(app: app, wake: app.wake)
                KariCompanionControls(app: app, live: app.live, camera: app.camera, settings: app.settings, bodyService: app.body, landscape: true)
            }
        }.padding(.horizontal, 24).padding(.vertical, 8)
    }
}

struct KariCompanionStopButton: View {
    @ObservedObject var app: KariAppModel
    var body: some View {
        Group {
            if #available(iOS 26, *) {
                button.glassEffect(.regular.interactive(), in: Circle())
            } else { button.background(.regularMaterial, in: Circle()) }
        }
    }
    private var button: some View {
        Button { Task { await app.stop() } } label: {
            Group {
                if app.phase == .stopping { ProgressView() }
                else { Image(systemName: "stop.fill").font(.title3) }
            }.frame(width: 44, height: 44)
        }.buttonStyle(.plain).foregroundStyle(.white)
        .disabled(app.phase == .stopping)
        .accessibilityLabel(L("退出陪伴")).accessibilityIdentifier("startExperience")
    }
}

private struct KariCompanionCameraWindow: View {
    @ObservedObject var camera: KariCamera
    var body: some View { KariCameraPreview(camera: camera).accessibilityIdentifier("companionCameraPreview") }
}
