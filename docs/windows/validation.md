# Windows 验证记录

日期：2026-10-28。

本文件区分已执行验证和待执行验收。当前开发主机为 macOS ARM64，没有 Windows 桌面环境。

| 层级 | 本轮状态 | 能证明什么 |
| --- | --- | --- |
| 平台无关核心场景 | macOS 和 Linux Docker：25/25 通过 | 状态机、取消、时序、目标/剪贴板变化等模拟行为 |
| 真实配置及日志产物 | macOS 和 Linux Docker：6/6 通过 | 配置读写和损坏回退、真实 ZIP 脱敏与会话关联、8 文件滚动保留 |
| Windows 桌面交叉编译 | 应用及原生冒烟项目均 Release 构建成功，零警告、零错误 | 源码与 Windows 引用兼容 |
| Windows x64、ARM64 自包含发布 | 原生 ARM64 Linux Docker 中完整 PowerShell 打包脚本执行成功，生成两个 ZIP 和 SHA-256 | 构建产物可以生成；不能证明 Windows 运行成功 |
| macOS 兼容性回归 | 原 Swift 应用构建成功，`--self-test` 返回 `SELF_TEST_OK` | 现有 macOS 构建入口与自检保持正常 |
| Windows 原生冒烟 | 已提供程序和 CI，尚未在当前环境执行 | 执行通过后才能证明真实 Win32 布局、剪贴板和自有窗口 Ctrl+V |
| 豆包 Windows 语音 | 当前没有实机，待验收 | 真实 IME、快捷键和最终文本行为 |
| Windows UU → Windows | 当前没有实机，待验收 | 剪贴板时延、窗口恢复和远端粘贴 |
| Windows UU → Mac | 当前没有实机，待验收 | 跨平台映射与远端粘贴 |
| ARM64 实机 | 当前没有实机，待验收 | 运行时及豆包/UU 安装兼容性 |

实机测试按 [acceptance.md](acceptance.md) 记录具体系统和客户端版本。CI 配置存在不等于工作流已经运行通过；交叉发布成功不等于二进制已经在 Windows 启动。

## 已执行命令

使用 .NET SDK 10.0.403。Linux 打包容器为 ARM64，包含 Microsoft .NET SDK 官方镜像和 PowerShell 7.5.0；源码复制进容器，产物单独挂载输出，未接入真实桌面、麦克风或 UU 会话。

```text
dotnet run --project windows/tests/DoubaoVoiceBridge.Tests -c Release
  25/25 passed
dotnet run --project windows/tests/DoubaoVoiceBridge.DiagnosticsTests -c Release
  6/6 passed
dotnet build windows/tests/DoubaoVoiceBridge.WindowsSmoke -c Release
  应用及冒烟程序交叉构建成功，0 警告，0 错误
pwsh -NoProfile -File scripts/build-windows.ps1
  核心 25/25、诊断 6/6，win-x64 和 win-arm64 发布及压缩成功
swift build -c debug -j 2
.build/debug/DoubaoVoiceBridge --self-test
  SELF_TEST_OK
```

另检查了工作流 YAML 语法、差异空白、ZIP CRC、包内运行时及文档、SHA-256 和 PE 机器类型。交付为未签名的预验证包，无需另装 .NET。

早先一次 x64 CPU 仿真容器中的 PowerShell 在压缩步骤异常退出，该次不完整 ZIP 已被替换；最终使用原生 ARM64 Linux 工具链完整执行。它属于构建环境测试记录，不是 Windows 应用运行结果。
