# 语音动作计划

**语言 / Language:** [简体中文](#简体中文) · [English](#english)

## 简体中文

把「前进十步」这类带次数或连续步骤的口令，收成一份动作计划，由手机按现有单次脉冲循环执行。实时语音链路保持不变。不为每一种说法各写一个场景。

最低兼容目标仍是 iOS 15。业务源码位于 `Native/Sources/KariNative/`，底盘脉冲定义位于 `FaceSource/frontend/js/embodiment/`。

## 现状

实时对话走云端多模态 Live API 的函数调用，不是 LangGraph、LangChain 或自研对话状态机。

| 环节 | 现状 |
| --- | --- |
| 麦克风 | `AVAudioEngine`，16 kHz PCM |
| 唤醒 | Apple `SFSpeechRecognizer`，只认「你好卡里」或 “Hey KARI” |
| 转写 | 服务端完成。Gemini 用 `inputTranscription`，智谱用 `input_audio_transcription` |
| 口语快路径 | `KariMemoryActionPolicy.scenario(for:)` 把整句收成一个场景名 |
| 模型工具 | Gemini 只有 `run_scenario(name)`。智谱多一个 `drive(direction)`，方向仅限前进、后退、左转、右转 |
| 执行 | 一次 `runScenario`，播放该场景的固定帧表 |
| 去重 | 两秒内同名动作视为同一次口令，第二次丢弃 |

口令里的「十步」「90 度」能通过正则，但只用来判断这是不是直接口令。数字不进入电机参数。

## 底盘预设

运动数值在 `movementCatalog.js`，场景名在 `scenarioCatalog.js`。下发报文是 `type: motion`，字段为 `linear`、`angular`、`duration_ms`、`ramp_ms`。正线速度向前，正角速度向右。没有角度字段。

| 说法 | 场景 | 线速度 | 角速度 | 时长 |
| --- | --- | --- | --- | --- |
| 前进、往前走 | `come_closer` | 0.05 | 0 | 300 ms |
| 后退、往后走 | `back_up` | -0.05 | 0 | 300 ms |
| 左转、往左 | `look_left` | 0 | -0.055 | 170 ms |
| 右转、往右 | `look_right` | 0 | 0.055 | 170 ms |
| 点头式确认 | `ack_yes` | 0.05 | 0 | 130 ms |
| 摇头式否认 | `ack_no` | -0.05 | 0 | 130 ms |

左转的目录斜坡是 90 ms。原生 `KariBodyProtocol` 把斜坡限制在时长的一半，170 ms 的脉冲实际发出 `ramp_ms` 85。标签为 `scenario_tiny_turn_left`。

眨眼、跳舞、进食等其余场景继续走原目录，本需求不改它们的帧表。

## 问题

「前进十步」和「前进」执行同一条 300 ms 脉冲。「左转九十度」和「左转」执行同一条 170 ms 脉冲。原因有三处：

1. 工具参数没有次数，场景帧表也不能按口令重复。
2. 正则和 `drive` 的方向枚举把说法收成一个名字。
3. 同名去重会吃掉短时间内的第二次调用。让模型连调十次工具，还会叠上蓝牙确认和打断。

## 目标

1. 模型只产出一份计划。计划由若干步组成，每步是方向加次数。
2. 手机上的解释器按次数循环现有脉冲。前进十步等于把 `come_closer` 的那一跳执行十次。
3. 开发者写一次解释器和上限，不为「十步」「两步再左转」各做一个场景。
4. 停止口令、用户打断、进入后台、租约失效时，停在步与步之间。
5. iPhone 13 以及一切没有 Apple Intelligence 的设备，用已经接好的云端文本模型填同一份计划。

## 计划

一步是四个底盘方向之一，加上一个整数次数。单步脉冲沿用上表，不新造速度。

- 次数下限为 1。缺省次数视为 1，因此单独说「前进」仍只走一次。
- 次数硬上限为 20。超出上限时拒绝整份计划并说明原因，不截断后悄悄执行。
- 连续说法收成多步，例如「前进十步再左转」是两步：前进 ×10，然后左转 ×1。
- 解释器在现有动作租约里逐步发送 `motion`，步与步之间等待本步时长。每步开始前检查停止、打断、后台和租约。

去重只针对同一句话被转写和工具各触发一次。计划内部的重复步放行。

## 规划器

实时语音仍负责听和说。规划只在这句被判定为动作口令时发生。

| 设备 | 谁来填计划 |
| --- | --- |
| iOS 26 且已开启 Apple Intelligence | Foundation Models 引导生成。硬件从 iPhone 15 Pro、iPhone 15 Pro Max、iPhone 16 全系及更新机型起 |
| 其他设备，含升到 iOS 26 的 iPhone 13 | 现有 Gemini 或兼容文本接口，产出同一份 JSON |

iPhone 13 能安装 iOS 26，不能使用端侧 Foundation Models。`SystemLanguageModel` 不可用时走云端，不向用户报错成功能失败。闲聊不加载端侧模型。

Gemini 与智谱的实时工具都改为提交这一份计划，避免两套语义。表情类场景仍可走原来的 `run_scenario`。

## 非目标

- 不把实时语音换成 LangGraph-Swift 或 OpenAI Agents SDK。前者是社区移植，后者没有官方 Swift 库。
- 不让模型在一次对话里连发十次电机工具。
- 不把「度」换算成精确转角。在有单独的角度标定之前，次数只重复现有脉冲。
- 不为本需求开启后台音频。进后台取消未完成的计划，与现在的身体停止一致。
- 不改遥控、视觉跟随和待机场景的执行路径。

## 验收

1. 「前进」执行 1 次 300 ms 前进脉冲。
2. 「前进十步」执行 10 次相同脉冲，步与步之间不把同名去重当成结束。
3. 「左转」仍是角速度 -0.055、持续 170 ms 的一次脉冲。
4. 「前进两步再右转」按顺序执行，中途说出停止口令后不再发下一步。
5. 次数 21 被拒绝，小车保持不动。
6. iPhone 13 上由云端文本模型填计划，解释器仍在本机循环。
7. 眨眼、跳舞等非底盘场景的行为与改动前一致。

## English

Turn counted or sequenced speech such as “forward ten steps” into one motion plan. The phone repeats the existing single pulse. The live voice path stays as it is. Each new phrasing does not get its own scene.

The deployment target remains iOS 15.

Live dialogue uses a cloud multimodal Live API and function calling. The microphone is 16 kHz PCM from `AVAudioEngine`. On-device speech recognition is only the wake phrase. Gemini and Zhipu transcribe on the server. A regex fast path and the model tools (`run_scenario(name)`, Zhipu `drive(direction)`) both collapse an utterance to one scenario name. The same name is dropped if it arrives again within two seconds. A spoken count or angle is accepted by the regex and then discarded.

Chassis presets, defined in `movementCatalog.js` and `scenarioCatalog.js`:

| Phrase | Scenario | Linear | Angular | Duration |
| --- | --- | --- | --- | --- |
| Forward | `come_closer` | 0.05 | 0 | 300 ms |
| Back | `back_up` | -0.05 | 0 | 300 ms |
| Turn left | `look_left` | 0 | -0.055 | 170 ms |
| Turn right | `look_right` | 0 | 0.055 | 170 ms |
| Nod | `ack_yes` | 0.05 | 0 | 130 ms |
| Shake | `ack_no` | -0.05 | 0 | 130 ms |

There is no degree field. Positive angular means right. The catalog ramp for a turn is 90 ms; native validation caps ramp at half the duration, so a 170 ms turn is sent with `ramp_ms` 85.

A plan is a list of steps. Each step is one of the four directions plus a repeat count. The default count is 1. The hard maximum is 20; a larger count rejects the whole plan. “Forward ten steps” repeats the `come_closer` pulse ten times. “Forward two steps then turn right” is two steps. The interpreter sends `motion` on the existing lease and checks stop, interruption, background, and lease validity before every step. Deduping applies to one utterance firing twice, not to repeats inside a plan.

The planner runs only for a motion command. On iOS 26 with Apple Intelligence enabled (iPhone 15 Pro, iPhone 15 Pro Max, iPhone 16 and later), Foundation Models guided generation fills the plan. Every other device, including an iPhone 13 on iOS 26, uses the existing cloud text model and the same JSON. Facial scenarios stay on `run_scenario`.

This work does not replace live voice with LangGraph or the OpenAI Agents SDK, does not issue ten separate motor tool calls, does not convert “degrees” into a calibrated angle, and does not keep driving in the background.
