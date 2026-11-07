import SwiftUI
import UIKit

// UIKit owns tab chrome and scroll safe areas. Hosting an individual native
// navigation hierarchy per page avoids an outer SwiftUI inset being swallowed
// by NavigationView's internal scroll view.
struct KariNativeTabs: UIViewControllerRepresentable {
    @Binding var selection: Int
    @ObservedObject var session: KariDeviceSession
    let pages: [AnyView]
    let language: String
    let canStart: Bool
    let start: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, start: start) }
    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.overrideUserInterfaceStyle = .dark
        controller.delegate = context.coordinator
        controller.tabBar.accessibilityIdentifier = "nativeTabBar"
        // Do not install a custom appearance/background. The system provides
        // Liquid Glass on iOS 26+, and the platform tab appearance on iOS 15–25.
        context.coordinator.install(pages, in: controller, language: language)
        updateUIViewController(controller, context: context)
        return controller
    }
    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.start = start
        if context.coordinator.language != language { context.coordinator.install(pages, in: controller, language: language) }
        let index = selection < 2 ? selection : selection + 1
        if controller.selectedIndex != index { controller.selectedIndex = index }
        controller.tabBar.items?[2].isEnabled = canStart && !session.busy && session.info["ota_mode"] as? Bool != true
    }

    @MainActor final class Coordinator: NSObject, UITabBarControllerDelegate {
        var selection: Binding<Int>
        var start: () -> Void
        var language = ""
        private var action: UIViewController?
        init(selection: Binding<Int>, start: @escaping () -> Void) { self.selection = selection; self.start = start }
        func install(_ pages: [AnyView], in controller: UITabBarController, language: String) {
            self.language = language
            let titles = [L("机器人"), L("人格"), L("记忆库"), L("设置")]
            let icons = ["wrench.and.screwdriver", "person.crop.circle", "books.vertical", "gearshape"]
            var controllers: [UIViewController] = []
            for index in pages.indices {
                if index == 2 {
                    let action = UIViewController(); action.view.backgroundColor = .black
                    let item = UITabBarItem(title: nil, image: UIImage(systemName: "play.fill"), tag: -1)
                    item.accessibilityIdentifier = "startExperience"
                    item.accessibilityLabel = L("开始陪伴"); item.accessibilityTraits = .button
                    action.tabBarItem = item; self.action = action; controllers.append(action)
                }
                let host = UIHostingController(rootView: pages[index].environment(\.locale, KariLocalization.shared.locale).preferredColorScheme(.dark))
                host.view.backgroundColor = .black
                host.tabBarItem = UITabBarItem(title: titles[index], image: UIImage(systemName: icons[index]), tag: index)
                host.tabBarItem.accessibilityIdentifier = "tab_\(index)"
                controllers.append(host)
            }
            controller.setViewControllers(controllers, animated: false)
        }
        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            if viewController === action { start(); return false }
            return true
        }
        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            guard viewController !== action else { return }
            selection.wrappedValue = viewController.tabBarItem.tag
        }
    }
}

struct KariNativeSettingsPage: View {
    @ObservedObject var app: KariAppModel
    @ObservedObject private var localization = KariLocalization.shared
    let robots: () -> Void
    let ai: () -> Void
    var body: some View {
        NavigationView {
            Form {
                if app.turnCalibrating {
                    Section(header: Text(L("标定转一圈"))) {
                        Text(L("已完成 %d 次右转", app.turnCalibrationPulses))
                        Button(L("完成")) { app.finishTurnCalibration() }
                        Button(L("取消标定")) { app.cancelTurnCalibration() }
                    }
                }
                Section(header: Text(L("连接与对话"))) {
                    Button(action: robots) { Label(L("连接机器人"), systemImage: "antenna.radiowaves.left.and.right") }
                    Button(action: ai) { Label(L("AI 服务"), systemImage: "waveform") }
                }
                Section(header: Text(L("应用与权限"))) {
                    Picker(L("界面语言"), selection: $localization.selection) { Text(L("跟随系统")).tag(KariAppLanguage.system); Text("简体中文").tag(KariAppLanguage.chinese); Text("English").tag(KariAppLanguage.english) }
                    Button(L("打开系统权限设置")) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    NavigationLink(L("语音与唤醒")) { KariWakeSettingsView(app: app, features: app.companion, wake: app.wake) }.accessibilityIdentifier("wakeSettingsLink")
                    NavigationLink(L("诊断")) { KariDiagnosticsView(app: app, features: app.companion) }
                }
                Section { Text(LM(app.notice)).font(.footnote).accessibilityIdentifier("runtimeNotice") }
            }.navigationTitle(L("设置"))
        }.navigationViewStyle(.stack)
    }
}
