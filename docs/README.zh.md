<p align="center">
  <img src="assets/icon.png" width="128" alt="Luka">
</p>

<h1 align="center">Luka</h1>

<p align="center">
  <strong>为 Mac 听到的一切配上实时字幕。</strong><br>
  通话、视频、会议，边听边转写、边翻译，并标出是谁在说话。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-black?style=flat-square" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/speech-Soniox%20stt--rt--v6-FF6A3D?style=flat-square" alt="Soniox">
  <a href="../LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT"></a>
</p>

<p align="center">
  <a href="../README.md">English</a> | <a href="README.ko.md">한국어</a> | <b>中文</b>
</p>

<p align="center">
  <img src="assets/hero.png" width="820" alt="Luka 记录窗口与字幕">
</p>

---

## 安装

在终端中粘贴：

```sh
curl -fsSL https://raw.githubusercontent.com/StableFluffy/luka/main/install.sh | sh
```

它会把最新版本安装到“应用程序”（已安装则更新），检查 Apple 签名与公证后打开 Luka。以后更新也用同一条命令。更喜欢磁盘映像？从 [Releases](../../../releases) 下载 `Luka-<版本>.dmg`，把 **Luka** 拖到 **应用程序**。

然后：

1. 在首个窗口粘贴 [Soniox API 密钥](https://console.soniox.com)。
2. 按 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>N</kbd>，并允许 **系统音频录制**。

需要 macOS 15 或更高版本；在 macOS 26 及以上使用 Liquid Glass。Soniox 按音频时长计费（[价格](https://soniox.com/pricing)）。

## 字幕

<p align="center">
  <img src="assets/captions.png" width="720" alt="字幕条">
</p>

悬浮在任何应用之上的玻璃字幕，全屏视频也不例外，且从不抢占焦点。
开始收听时出现，结束后淡出；随时可按 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>C</kbd> 隐藏。

| 操作 | 效果 |
| --- | --- |
| 拖动上下边缘 | 调整行数（1–6） |
| 拖动两侧 | 调整宽度 |
| 放到屏幕中央附近 | 自动居中 |
| 鼠标悬停 | 语言、音源、大小、锁定控件 |
| 点击说话人名字 | 重命名，全局即时生效 |
| 锁定 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd> | 点击穿透；悬停出现 **解锁** |

## 会话

每次转写都会作为会话出现在侧栏，并自动保存。
点击标题即可改名。用 <kbd>⌘</kbd><kbd>.</kbd> 结束后可 **继续收听**、编辑、或用 <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd> 复制全部。

同一个人被分成两位说话人？点开名字选择 **与…是同一人**。

## 快捷键

在任意应用中可用：

| 按键 | 操作 |
| --- | --- |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>N</kbd> | 新建转写 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>R</kbd> | 开始 / 暂停 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>C</kbd> | 显示 / 隐藏字幕 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>T</kbd> | 显示 / 隐藏记录 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd> | 锁定 / 解锁字幕 |

在 Luka 中：<kbd>⌘</kbd><kbd>E</kbd> 为正在说话的人命名，<kbd>⌘</kbd><kbd>1</kbd> / <kbd>⌘</kbd><kbd>2</kbd> 切换窗口，<kbd>⌘</kbd><kbd>+</kbd> <kbd>⌘</kbd><kbd>−</kbd> 文字大小，<kbd>⌘</kbd><kbd>↑</kbd> <kbd>⌘</kbd><kbd>↓</kbd> 字幕行数。

## 模式

| 模式 | 用途 |
| --- | --- |
| 翻译 | 任何语言 → 一种语言 |
| 双向 | 对话：双方互译 |
| 转写 | 只记录，不翻译 |

可收听 Mac 音频、麦克风或两者。界面支持 English、한국어、中文。

## 会议与面试

设置 › 通用 › **会议与面试**（菜单栏里也有）：

| 选项 | 作用 |
| --- | --- |
| 按声音来源区分“我”和“对方” | 选择 **Mac 音频 + 麦克风** 时，麦克风固定是“我”，Mac 音频固定是“对方”，分两条 Soniox 连接识别，不再靠声纹猜测。开启期间多一条连接的费用。 |
| 翻译我说的话 | 在“我 / 对方”模式下，选择是否翻译你自己说的话。 |
| 固定显示最新的问题 | 把对方最新问的问题固定在字幕上方，方便边答边看。点 × 取消固定。默认关闭。 |

## 用量

设置 › 通用 › **用量** 显示本次会话、本月、上月发送给 Soniox 的音频时长和估算费用（每条连接转写 $0.12/小时、翻译 $0.18/小时）。菜单栏显示本月合计。

## 实时总结

设置 › **总结**：可选任意 OpenAI 兼容模型（OpenAI、DeepSeek、通义千问、OpenRouter、Ollama…）或 Claude，使用单独的 API 密钥。转写时，转写窗口右侧会实时显示对话总结（要点、结论、问题与下一步）：每积累几百字更新一次，每隔几次根据完整转写重写，前面的内容也会随之修订。点 ↻ 立即重写；总结随会话保存，导出 Markdown 时放在开头。转写文字会发送给模型服务商；用 Ollama 则不离开本机。

## 助手模式

在总结栏顶部、菜单栏或“设置 › 助手”里选择 **讲座 / 会议 / 面试**。选择模式会一次设好下面这些开关，之后每一项都还能单独调整：

| | 讲座 | 会议 | 面试 |
|---|---|---|---|
| 总结 | 关 | 开（往下追加） | 关 |
| 回答 | 关 | 关 | 开 |
| 我 / 对方 | 关 | 开（其他人编号） | 开 |
| 钉住最新问题 | 关 | 关 | 开 |
| 润色我的回答 | — | — | 开 |

“设置 › 助手 › 本次对话”填应聘岗位和一条本次说明，总结和回答共用；“设置 › 知识库”放长期不变的文件、文件夹和我的笔记。回答边生成边显示：问题先出现，接着是一句中文要点，再是要点和可借用的英文原话（强调色）。

## 面试回答和问题追踪

面试模式下的回答是"提示骨架"，不是照念的稿子：一行要点，加最多三条按题型给的编号提示（行为题：情境 → 我做了什么 → 带数字的结果；产品 / 指标 case：澄清 → 北极星和护栏 → 思路；技术题：答案 → 何时用 → 坑），再加一行 ⚓，写明知识库里你自己的项目、经历或数字以及出处文件。不编造：没有匹配时会直接说明。

你答完后，润色只给一条下一轮就能用的修正；答没答全、用了哪段经历、更顺的说法都保存下来留给会后复盘。总结标签页会列出已问到的每道题，标 ✓ 已答全 / ⚠ 漏了一部分和用了哪段经历，直接从已有的回答拼出来，不额外花钱。每个会话会记住自己的模式。

## 会议：跟你有关、标签和帮我跟上

在“设置 › 知识库 › 你”里填你的名字。会议模式下，笔记顶部有一条**跟你有关**：最近提到你名字的话，以及笔记里分给你的待办。笔记用 [Decision]、[Action → 负责人]、[Open ?]、[Number] 标注，各有颜色；推翻之前的决定时加一行 ↺，不改原来那条。问到你的问题会给三条回复提纲（我的立场、依据、下一步）。笔记上方的时钟按钮是**帮我跟上**：只在点的时候调用一次，告诉你刚才说了什么。

## 会话标签和批量操作

右键会话 › **标签…** 给会话打标签；标签显示在会话下方和列表顶部的标签栏里，点一个标签就只列出带这个标签的会话。按住 ⌘ 或 ⇧ 点击可以多选：右键可以一起**加标签**、**复制**或**删除**，窗口中间也有对应按钮。

## Soniox 账户

设置 › 通用 › **Soniox 账户** 显示 Soniox 官方数据：本月该密钥所属项目的实际费用（含所有应用），以及填入组织 API 密钥（`snx_org_…`）后的预付余额，余额也会显示在菜单栏。

## 隐私

音频通过 WebSocket 直接从 Mac 发送到 Soniox，没有 Luka 服务器。
API 密钥以 AES-GCM 加密保存在 `~/Library/Application Support/Luka/`，会话以 JSON 文件保存在旁边。

## 从源码构建

```sh
./scripts/build-app.sh --install   # ~/Applications/Luka.app
./scripts/build-app.sh --dmg       # build/Luka-<版本>.dmg
swift test                         # 回放录制的 Soniox 流
```

使用 Xcode 26 / Swift 6.2 构建，可在 macOS 15 及以上运行。

## 许可证

MIT
