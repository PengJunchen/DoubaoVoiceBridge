# Windows 方案、技术依据与兼容边界

调研日期：2026-10-28。目标是让 Windows 主控机使用本机豆包语音，向 UU 控制的 Windows 或 Mac 输入文字。

## 现有机制

macOS 实现并不直接调用豆包识别 API，也不自行捕获音频。`ControlHoldMonitor.swift` 监测触发手势并向本机输入会话发出配置的豆包快捷键；`ComposerPanelController.swift` 提供可接收输入法提交的本机文本框，等待标记文字结束且文本稳定；`SessionCoordinator.swift` 管理会话；`UURemoteDelivery.swift` 恢复原 UU 窗口，把文字写入系统剪贴板，等待同步，再发送粘贴组合键。`UURemoteTarget.swift` 和剪贴板代次检查用于减少错误投递、避免覆盖后来的复制。

Windows 版的目标环境为 Windows 10 22H2 / Windows 11，x64 与 ARM64 交互桌面；旧版系统不在本应用的支持范围内。Windows 版保留这套职责划分和行为约束。实现位于独立 `windows/` 子树，现有 Swift 包及 macOS 发布流水线继续使用原入口。两平台共享的是流程语义和安全边界，暂不引入跨语言核心，也不强制统一两种系统的配置格式。

## 可行性判断

在 Windows 可接收输入法提交的本地文本框上完成豆包听写，再通过 UU 的剪贴板通道投递，具备公开系统接口和产品功能依据。完整自动化是否适配具体版本，必须由实机确认。

| 环节 | 已有依据 | 尚待验证 |
| --- | --- | --- |
| 本机识别 | [豆包官网](https://shurufa.doubao.com/pc)列出 Windows 下载及语音输入能力 | 所装版本的语音快捷键、按住/切换停止方式、当前输入法和麦克风权限 |
| 文字接收 | Windows 文本控件支持输入法提交；[WM_IME_COMPOSITION](https://learn.microsoft.com/en-us/windows/win32/intl/wm-ime-composition)区分组合更新与结果提交 | 豆包实际采用的 TSF/IMM 路径、延迟整理和语音浮层焦点行为 |
| 跨端文字 | 网易[隐私政策](https://uuyc.163.com/contact/20240402/40294_1146067.html)说明远控期间跨端传输剪贴板内容 | 两端开关、网络延迟、重连、客户端版本、剪贴板工具干扰 |
| Windows 控 Mac | 网易[Mac 被控功能页](https://uuyc.163.com/features/mac/)提供该使用场景 | 具体 UU 版本的 Ctrl/Win/Alt 到 Command 映射和远端输入焦点 |
| 输入注入 | [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)可发送按键序列 | 豆包、UU 是否接受模拟事件；权限级别和拦截工具影响 |

官网内容仅证明能力方向，不证明本应用端到端可用；没有把未找到的豆包私有控制 API、UU 同步确认 API 或统一 Mac 键位映射当作已存在接口。

## 分层

```text
Windows 托盘 / 设置 / 本地 IME 文本框
                 │
        BridgeCoordinator (net10.0)
          │              │
    IBridgePlatform    IBridgeLog
          │              │
Win32 窗口/键盘/剪贴板   轮转 JSONL + 脱敏 ZIP
          │
       UU 客户端 → 远端剪贴板 / 粘贴键
```

- `DoubaoVoiceBridge.Core`：不引用 Windows 桌面库。管理 Idle、Listening、Finalizing、Delivering、Failed，控制并发、取消、定时稳定判断和最多一次投递尝试。使用可替换平台与时钟进行确定性测试。
- `DoubaoVoiceBridge.Windows`：WinForms 原生文本框和托盘，处理 IME 组合状态；原生适配器负责 Win32 句柄、进程身份、剪贴板及输入注入。
- `GlobalTrigger`：监听专用功能键，忽略模拟事件，匹配键的按下/抬起，避免触发器递归。回调只做轻量判断并排队到 UI，不在钩子中等待识别或同步。
- 会话健康检查每 500 ms 运行一次：模拟听写失去本机焦点或持续超过 5 分钟时暂停，尽力释放本应用持有的按键并保留文字。切换式录音在焦点丢失后要求手动检查停止，不向其他窗口补发停止组合键；手动和测试模式不受此时限影响。
- `DiagnosticLog`：日志只有元数据；每条带 UTC 时间、运行 ID、会话 ID、事件和结构化字段。每个文件约 2 MiB，最多保留 8 个；导出当前配置的脱敏副本和构建信息。

## 一次会话

1. 用户主动绑定 UU 可执行程序，触发时捕获当前 UU 窗口句柄、PID、进程启动时间与完整路径，仅在内存/本地设置中使用路径。相同程序的不同窗口也要与本次捕获窗口一致。
2. 展示并聚焦本机文本框。默认手动启动/停止豆包；模拟模式先等物理修饰键松开，再发配置的启动手势。仅向本机听写框发送启动/停止键。
3. 结束后等待非空、没有组合输入、保持焦点且足够稳定的文字。默认稳定 700 ms，至少结束后 450 ms，默认 12 秒超时。该判断是启发式，不代表收到豆包的完成通知。
4. 默认等待用户检查并点击粘贴。自动粘贴需用户开启，仍通过相同检查。
5. 恢复原 UU 窗口并验证身份，写入 Unicode 剪贴板，默认等待 1000 ms；再次检查文字及原窗口，检查物理修饰键后发送完整粘贴组合键。始终不发送 Enter，也不依据“已注入”宣称远端已经收到。
6. 可选剪贴板恢复默认关闭。开启后只备份能够安全复制的文本、HTML、RTF、区域设置等字节格式，总量限制为 8 MiB；图片、文件、未知格式或超限内容无法安全备份时拒绝写入。恢复时在剪贴板锁内确认代次和所有权，后续复制会让恢复失效。

## 为什么不能直接照搬 macOS

[SetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow)受系统焦点规则限制，函数成功调用也不能代替前台窗口复核。应用在激活失败或目标变化时保留文字并停止。

[SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)受 UIPI 限制，通常只能向相同或更低完整性级别的程序注入，而且返回值不保证能指出 UIPI 原因。返回注入数量不足时不能自动重试，因为部分事件可能已经发生；应用尝试释放自己拥有的按键，并要求用户检查实际结果。通常让桥接、豆包与 UU 以普通用户运行，避免只把其中一个提升到管理员。

[LowLevelKeyboardProc](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc)需要消息循环且受回调超时限制，超时甚至可能被系统无声移除。专用功能键设计避免把 macOS 单 Control 手势的延迟与远控组合键重放直接移植到 Windows。全屏游戏或特殊键盘驱动仍可能干扰，需要实机报告。

[剪贴板代次](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getclipboardsequencenumber)可判断本地是否发生更新，不能判断 UU 已经同步到远端。同样文字被 UU 重新发布时可以继续粘贴，但不再声称拥有恢复权。同步等待只能调节，无法构成远端确认。

Windows 的 Win+V 通常有本地功能；是否作为远端 Command+V，取决于 UU 键盘映射。本版不根据远端操作系统自动猜测，明确提供 Ctrl+V、Win+V、Alt+V 三种选择并要求逐项测试。

## 明确限制

- 没有识别服务 SDK、音频保存、豆包账号凭证或私有协议；识别能力和网络处理由用户安装的豆包负责。
- 没有远端插件和回执，无法检测远端文本框、会话在线状态或实际粘贴次数。句柄检查不能识别 UU 同一个窗口内切换到另一台设备；投递期间请勿在 UU 内切换会话。
- 同一窗口内远端输入框变化、UU 内部会话变化、未提交的 TSF 状态及豆包延迟整理仍可能超出本地观测范围。自动投递必须在验证后开启。
- 不支持 Windows 安全桌面、锁屏和服务会话。ARM64 编译成功不等于豆包/UU ARM64 组合可用。
- Win32 剪贴板的多格式恢复本身并非事务：持锁与所有权检查可以避免常规覆盖，但系统写入中途失败仍可能只恢复部分格式，不能宣称任意故障下无损。
- 正常退出会尝试释放已注入的按键并清理受所有权保护的剪贴板。强制结束、系统崩溃或断电无法保证执行清理。

验收和故障回传以 [acceptance.md](acceptance.md) 为准。实际执行的检查另记于 [validation.md](validation.md)，不把计划中的 CI 或实机测试标成通过。
