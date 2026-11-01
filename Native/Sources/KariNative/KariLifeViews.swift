import SwiftUI

struct KariIdleScenesView: View {
    @ObservedObject var features: KariCompanionFeatures
    @State private var importing = false
    @State private var exporting = false
    @State private var document = KariJSONDocument()
    @State private var message = ""
    var body: some View {
        Form {
            Section(header: Text(L("全局节奏"))) {
                interval("首次待机", path: \.first)
                interval("静默期间", path: \.silent)
                interval("对话间隙", path: \.conversation)
                KariScaleControl(title: L("全局速度倍率"), value: $features.idleSettings.speedScale, range: 0.25...1.5, step: 0.25)
                KariScaleControl(title: L("全局时长倍率"), value: $features.idleSettings.durationScale, range: 0.5...2, step: 0.25)
                KariScaleControl(title: L("最短重复间隔秒数"), value: $features.idleSettings.repeatGap, range: 0...600, step: 5)
                Text(L("播放语音时只使用表情；身体动作仍需本次运动许可。")).font(.footnote)
            }
            Section(header: Text(L("内置场景"))) {
                ForEach(features.catalog) { scene in
                    NavigationLink { KariIdleSceneDetail(features: features, scene: scene) } label: {
                        HStack { Text(sceneName(scene)); Spacer(); Image(systemName: scene.body ? "figure.walk" : "face.smiling"); if !features.sceneOptions(scene.id).enabled { Text(L("已关闭")).font(.caption) } }
                    }.accessibilityIdentifier("scene_" + scene.id)
                }
            }
            Section(header: Text(L("陪伴配置"))) {
                Button(L("导入陪伴配置")) { importing = true }.accessibilityIdentifier("importCompanionConfiguration")
                Button(L("导出陪伴配置")) { do { document = .init(data: try features.exportedConfiguration()); exporting = true } catch { message = L("配置无效，原配置已保留") } }
                Button(L("恢复默认场景"), role: .destructive, action: features.resetScenes)
                Text(L("陪伴配置包括人格、行为、场景和唤醒设置，不包含凭据或运行记录。")).font(.footnote)
                if !message.isEmpty { Text(message) }
            }
        }.navigationTitle(L("待机场景"))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 131_072 else { throw PolicyError.invalidProfile }
                try features.importConfiguration(Data(contentsOf: url)); message = L("陪伴配置已保存")
            } catch { message = L("配置无效，原配置已保留") }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "KARI-companion") { if case .failure = $0 { message = L("导出未完成") } }
    }
    private func interval(_ title: String, path: WritableKeyPath<IdleSceneSettings, IdleInterval>) -> some View {
        VStack(alignment: .leading) {
            Text(L(title)).font(.headline)
            Stepper(value: Binding(get: { features.idleSettings[keyPath: path].minimum }, set: { value in
                features.idleSettings[keyPath: path].minimum = value
                features.idleSettings[keyPath: path].maximum = max(value, features.idleSettings[keyPath: path].maximum)
            }), in: 3...300, step: 1) { Text(L("最短秒数") + ": \(Int(features.idleSettings[keyPath: path].minimum))") }
            Stepper(value: Binding(get: { features.idleSettings[keyPath: path].maximum }, set: { features.idleSettings[keyPath: path].maximum = $0 }), in: features.idleSettings[keyPath: path].minimum...600, step: 1) { Text(L("最长秒数") + ": \(Int(features.idleSettings[keyPath: path].maximum))") }
        }
    }
}
func sceneName(_ scene: IdleScene) -> String { KariLocalization.shared.language == "en" ? scene.title : scene.titleZH }

struct KariScaleControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var body: some View {
        Stepper(value: $value, in: range, step: step) { HStack { Text(title); Spacer(); Text(value, format: .number.precision(.fractionLength(2))).monospacedDigit() } }.accessibilityLabel(title)
    }
}

struct KariIdleSceneDetail: View {
    @ObservedObject var features: KariCompanionFeatures
    let scene: IdleScene
    @State private var options = IdleSceneOptions()
    var body: some View {
        Form {
            Section {
                Toggle(L("启用此场景"), isOn: $options.enabled)
                KariScaleControl(title: L("相对权重"), value: $options.weight, range: 0...10, step: 0.5)
                KariScaleControl(title: L("冷却秒数"), value: $options.cooldown, range: 0...600, step: 5)
                Picker(L("适用状态"), selection: $options.availability) {
                    Text(L("始终可用")).tag(IdleAvailability.always)
                    Text(L("清醒时")).tag(IdleAvailability.awake)
                    Text(L("休眠时")).tag(IdleAvailability.sleeping)
                }
                if scene.body {
                    KariScaleControl(title: L("场景速度倍率"), value: $options.speedScale, range: 0.25...1.5, step: 0.25)
                    KariScaleControl(title: L("场景时长倍率"), value: $options.durationScale, range: 0.5...2, step: 0.25)
                }
            }
            Section(header: Text(L("预览"))) {
                Text(L(scene.body ? "身体预览会真实移动机器人，请留出空间。" : "表情预览不移动身体。")).font(.footnote)
                Button(L("预览一次")) { features.previewScene(scene) }.accessibilityIdentifier("previewIdleScene")
                Button(L("停止预览"), role: .destructive, action: features.cancelPreview)
                Text(LM(features.app?.notice ?? "")).font(.footnote)
            }
        }.navigationTitle(sceneName(scene))
        .onAppear { options = features.sceneOptions(scene.id) }
        .onChange(of: options) { features.setSceneOptions($0, id: scene.id) }
        .onDisappear { features.cancelPreview() }
    }
}

struct KariLifeStateView: View {
    @ObservedObject var features: KariCompanionFeatures
    var body: some View {
        List {
            Section {
                Text(L("生命状态是模拟数值，不代表真实感受或传感器测量。")).font(.footnote)
                Text(L("每次开始陪伴重置；结束后可查看最近状态。")).font(.footnote)
            }
            Section(header: Text(L("生命状态"))) {
                meter("精力", features.lifeState.energy)
                meter("无聊", features.lifeState.boredom)
                meter("好奇", features.lifeState.curiosity)
                meter("亲近", features.lifeState.affection)
                meter("孤独", features.lifeState.loneliness)
                meter("舒适度", features.lifeState.comfort)
                row("情绪", LM(features.lifeState.mood))
                row("注意力", LM(features.lifeState.attention))
                row("休眠", L(features.lifeState.sleeping ? "是" : "否"))
                row("变化原因", reasonName(features.lifeState.reason))
                row("用户身份", L("未知")); row("距离", L("未知")); row("障碍", L("未知"))
            }
            Section(header: Text(L("最近决策"))) {
                ForEach(features.decisions.suffix(20).reversed()) { item in VStack(alignment: .leading) { Text(LM(item.kind)); Text(reasonName(item.detail)).font(.caption) } }
            }
        }.navigationTitle(L("生命状态")).accessibilityIdentifier("lifeStatePage")
    }
    private func reasonName(_ reason: String) -> String { features.catalog.first(where: { $0.id == reason }).map(sceneName) ?? LM(reason) }
    private func meter(_ title: String, _ value: Double) -> some View { VStack(alignment: .leading) { HStack { Text(L(title)); Spacer(); Text(value, format: .percent.precision(.fractionLength(0))) }; ProgressView(value: value) }.accessibilityElement(children: .combine) }
    private func row(_ title: String, _ value: String) -> some View { HStack { Text(L(title)); Spacer(); Text(value).foregroundStyle(.secondary) } }
}

struct KariWakeSettingsView: View {
    @ObservedObject var app: KariAppModel
    @ObservedObject var features: KariCompanionFeatures
    @ObservedObject var wake: WakeCoordinator
    @State private var checking = false
    var body: some View {
        Form {
            Section(header: Text(L("唤醒模式"))) {
                Toggle(L("使用唤醒词开始对话"), isOn: $features.wakeSettings.enabled).accessibilityIdentifier("enableWakeWord")
                    .disabled(!app.settings.configuration.isLive)
                Picker(L("唤醒短语"), selection: $features.wakeSettings.preset) { ForEach(WakePreset.allCases, id: \.self) { Text($0.title).tag($0) } }
                Stepper(value: $features.wakeSettings.silenceTimeout, in: 30...300, step: 10) { Text(L("对话静默超时秒数") + ": \(Int(features.wakeSettings.silenceTimeout))") }
                Text(L("仅 Gemini／标准 Vertex／智谱实时语音支持唤醒模式；文字模式保持原有方式。")).font(.footnote)
                Text(L("唤醒后连续对话；静默超时返回等待，不自动恢复身体动作。")).font(.footnote)
            }
            Section(header: Text(L("本地识别"))) {
                Text(LM(wake.availability)).accessibilityIdentifier("wakeAvailability")
                Button(L("检查本地识别权限")) {
                    checking = true
                    Task { _ = await wake.checkAvailability(features.wakeSettings.preset, requestPermission: true); checking = false }
                }.disabled(checking)
                if checking { ProgressView() }
                Text(L("等待期间不上传声音或画面。不支持本地识别时保留手动唤醒，不使用网络识别。")).font(.footnote)
                Text(L("只在前台陪伴时监听；进入后台或电话中断后需手动恢复。")).font(.footnote)
            }
        }.navigationTitle(L("语音与唤醒"))
    }
}

struct KariWakeControls: View {
    @ObservedObject var app: KariAppModel
    @ObservedObject var wake: WakeCoordinator
    var body: some View {
        if app.companion.wakeSettings.enabled && app.settings.configuration.isLive {
            VStack(spacing: 4) {
                Text(LM(wake.message)).font(.callout).accessibilityIdentifier("wakeStatus")
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    Text("connected=\(app.live.connected) video=\(app.live.sentVideoFrames) microphone=\(app.live.microphone)").font(.caption).accessibilityIdentifier("wakePrivacyCounters")
                }
                HStack {
                    if wake.phase == .waiting {
                        Button(L("手动唤醒"), action: wake.wake).accessibilityIdentifier("manualWake")
                        Button(L("重试本地监听")) { Task { await wake.resume() } }
                    } else if wake.phase == .conversation {
                        Button(L("回到等待唤醒"), action: wake.wait).accessibilityIdentifier("returnToWake")
                    } else if wake.phase == .suspended {
                        Button(L("恢复采集")) { app.recoverCapture() }.accessibilityIdentifier("resumeWakeCapture")
                    } else { ProgressView() }
                }.buttonStyle(.bordered)
            }
        }
    }
}
