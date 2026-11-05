# Agent 自验证方案

日期：2026-11-04。状态：方案，代码未改。

Agent 改完 App 之后，先在这台 Mac 上把「决定」验绿，再请人装到 iPhone 上连车。真机仍然由人做。Agent 不负责把车开走，也不在默认检查里调用智谱。

## 现在为什么还是要人提前上机

仓库里已经有三层检查，推送时 CI（`.github/workflows/check.yml`）会跑前两层加上无签名编译：

| 检查 | 命令 | 实际覆盖 |
| --- | --- | --- |
| 隐私与本地化 | `python3 scripts/check-privacy.py`、`python3 scripts/check-localization.py` | 密钥、本机路径、Team ID、文案键 |
| Mac 上的原生测试 | `npm run test:native`（`scripts/test-native.py`） | 设备协议、设置、动作协调、部分 Live 配置。不签名、不连手机、不连车 |
| 无签名编译 | `xcodebuild -scheme KARI -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | 工程能编过 |
| 真机测试 | `KARI_TEST_DEVICE_ID=… npm run test:device` | 需要已配对的 iPhone。脚本主动跳过 `testConfiguredLive…OnPhone` 这几条实时语音测试 |

`scripts/test-native.py` 用 Mac 上的 `swiftc` 只编译一份源文件名单。名单里有 `KariLiveWire`、`KariBodyProtocol`、`KariPlaybackQueue` 等，没有 `KariAIService`、`KariAppModel`、`KariAudioOutput`。实时语音和控车的决定写在后面这几个文件里，所以 `test:native` 可以全绿，而下面三件事仍然要装到手机上才看得到：

- 播放期间麦克风被丢掉。`KariLiveService.startMicrophone` 在说话或回答未结束时把 `echoUntil` 推到大约 0.45 秒之后，这段时间直接 `return`，不上送 PCM。服务端因此听不到打断。
- 「前进」要落到车上。`drive` / `run_scenario` 经 `KariMemoryActionPolicy.resolveToolScenario` 变成 `come_closer`、`back_up`、`look_left`、`look_right`，再由 `onScenario` 进入 `runScenario`。问句和资料问答不能授权动作。
- 同一口令两秒内不发第二次。`claimMotion` 在 2 秒内拒绝同名动作，用来挡住工具调用和转写各触发一次。

`drive` 今天只有 `direction`（前进、后退、左转、右转），还没有 `count`。「前进三次」仍是待做功能。本方案把次数也算进第一批断言，等这个参数落地时一起验。

模拟器替不了车。iOS 模拟器没有到这块 ESP32 的蓝牙。云端 Agent 也开不了这台 iPhone。智谱 Realtime 按分钟计费，默认检查和 CI 都不调用它。

## 门禁

分两截。没过第 2 截，不把包装给人去连车。

### 第 1 截：每次改完先跑现有检查

在开发机上执行：

```sh
python3 scripts/check-privacy.py
python3 scripts/check-localization.py
npm run test:native
xcodebuild -project KARI.xcodeproj -scheme KARI -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/ci \
  CODE_SIGNING_ALLOWED=NO build
```

这一截挡住编译失败、旧协议测试回退，以及把密钥或本机路径提交进去。它盖不住打断和控车。

### 第 2 截：不联网、不连车的行为测试

把「决定」从麦克风、扬声器、WebSocket 和蓝牙里拆出来，放进 `npm run test:native` 已经在用的那种 Mac 测试。不打开智谱，不占分钟数。

做法两选一，优先能让 `swiftc` 单独编过的那一种：

- 把回声窗、口令映射、动作去重抽成不依赖 `AVAudioEngine` 和 `URLSession` 的函数，加进 `scripts/test-native.py` 的源文件名单。
- 或者沿 `KariLiveWire` 做一个假实现：喂入工具调用和转写事件，记录它发出的场景名，不断开真实网络。

第一批只断言这三件事：

1. **前进 N 次。** `drive(direction: 前进, count: 3)` 排队三次 `come_closer`。后退、左转、右转同样映射到 `back_up`、`look_left`、`look_right`。问句和「文档说请前进」不能授权动作。当前工具还没有 `count`，这条跟复合指令一起落地。
2. **播放期麦克风。** 给定「正在播放 / 回答未结束 / 已经安静」，断言这段 PCM 是继续上送，还是被回声窗丢掉。今天的代码是丢掉。若要做成可打断，测试改成断言仍上送，并写明短忽略窗的边界。
3. **两秒去重。** 同一场景名在 2 秒内第二次 `claimMotion` 被拒绝；超过 2 秒或换成另一个场景名则接受。

Agent 改到实时语音或控车时，要为这次改动补上对应断言，并在交给人之前把第 1 截和第 2 截都跑绿。

### 人仍做的真机

第 2 截绿了之后，Agent 只列出最多三个要看的现象，例如：

- 模型还在说「好的」时可以打断。
- 说一次「前进三次」，车走三步，而不是三轮对话。
- 前进、后退、左转、右转的方向对。

人用自己的签名装到 iPhone 上，连自己的车看这三点。轮子有没有转、喇叭里的声音、房间回声，不在 Agent 的通过标准里。

`npm run test:device` 继续要求本人在场，并且继续默认跳过会打到真实模型的 `testConfiguredLive…OnPhone`。确认要花智谱或 Gemini 的分钟数时，再在 Xcode 里单独点那几条。

## 先不做

- 用模拟器假装连上小车。
- 让 CI 默认连接智谱或上传麦克风。
- 假蓝牙外设、把一次真车会话录下来回放。这两项可以在第 2 截稳定之后再加，用来核对字节和时序，不能代替上面三条行为断言。
