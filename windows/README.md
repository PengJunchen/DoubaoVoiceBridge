# 远控听写 · Windows v0.1.0 预验证版

Windows 原生托盘应用：在本机豆包输入法中完成语音识别，再通过 UU 剪贴板同步粘贴到原远控会话。与现有 macOS 应用遵循同一工作流程，Swift/macOS 源码不受影响。

目前的交付是供 Windows 实机验证的版本。跨平台构建和模拟测试不能证明豆包模拟快捷键、UU 剪贴板同步或远端 Mac 键位映射已经可用。验证步骤见 [实机验收](../docs/windows/acceptance.md)，实现依据和限制见 [架构与可行性](../docs/windows/architecture.md)。ZIP 包内对应文档位于 `docs/`。

## 首次运行

目标运行环境为 Windows 10 22H2 或 Windows 11 的 x64 / ARM64 交互桌面，建议优先验证 Windows 11；更早系统不在支持范围内。实际支持范围还取决于豆包和 UU 客户端。先从[豆包官网](https://shurufa.doubao.com/pc)安装 Windows 输入法，并从[网易 UU 官网](https://uuyc.163.com/download/)安装 UU。确认豆包在普通本机文本框可以完成语音输入，UU 两端可以手动复制粘贴。

1. 解压匹配本机架构的完整 ZIP，运行 `DoubaoVoiceBridge.exe`。自包含包无需另装 .NET。应用尚未数字签名。
2. 点击「绑定 UU 会话窗口」，在 5 秒内切换到真正的 UU 远程桌面窗口；核对弹出的程序名后确认。不要绑定设备列表或无关程序。绑定匹配的是该程序路径，每次听写还会锁定当时的具体窗口。
3. 保持默认的「手动启动 / 停止豆包」、关闭自动粘贴与剪贴板恢复。勾选「远控键仅打开测试文字框」，保存设置。
4. 在 UU 内点选远端记事本或文本编辑输入框，按 F8，输入无敏感内容的测试文字，点「粘贴到原 UU 会话」。观察文字是否只出现一次，且没有发送或执行命令。
5. 测试成功后关闭测试模式。回到 UU 按 F8；本机听写框获得焦点后，使用真实的豆包快捷键开始和停止录音，点击「完成识别」，核对文字，再点击粘贴。
6. 完成验收后才切换到模拟按住/切换模式，设置与豆包完全一致的主键、左右修饰键；确认模拟键被豆包接受后，再按需要开启自动粘贴。

F8 可改为 F1–F24；它在绑定程序的前台窗口内独占，不再把该功能键传给远端。其他应用中照常使用。按住式或切换式模拟启动后，松开远控键会结束识别。手动模式由用户亲自停止豆包，再点击完成识别。测试模式复选框只对当前运行有效。

远端为 Windows 时通常使用 Ctrl+V。远端为 Mac 时先测试 UU 的 Ctrl/Command 映射；只有确定 UU 配置会把 Win 或 Alt 转换为 Command，才选择相应粘贴键。Win+V 也可能打开本机剪贴板历史；没有通用映射保证。应用只发送配置的粘贴组合键，不发送 Enter。

## 日志回传

从设置或托盘点击「导出诊断 ZIP」。日志及设置位于 `%LOCALAPPDATA%\DoubaoVoiceBridge`。诊断包包含运行环境、构建提交、脱敏配置、带会话标识的滚动事件，不包含听写正文、音频、剪贴板正文、窗口标题或绑定程序路径。

另外提供：故障发生时间（含时区）、两端系统、豆包和 UU 版本、触发方式、期望结果和实际结果。请用无敏感内容的短句复现。完整模板见[实机验收与日志回传](../docs/windows/acceptance.md)。

## 从源码构建

安装 .NET 10 SDK；打包使用 PowerShell 7，可在 Windows、macOS 或 Linux 交叉发布：

```powershell
dotnet run --project windows/tests/DoubaoVoiceBridge.Tests -c Release
pwsh ./scripts/build-windows.ps1
```

输出到 `dist/windows/`，包含 x64、ARM64 自包含 ZIP、SHA-256 和每个包的 `build-info.json`。默认先运行核心测试；`-Runtime win-x64` 可只构建一个架构。`-SkipTests` 仅用于已完成测试后的重复打包。ZIP 尚未进行代码签名。

Windows 项目的产品与程序集版本统一由 `windows/Directory.Build.props` 定义，当前与 macOS 一致为 `0.1.0`。打包脚本同时校验 Windows manifest 版本，避免包名、程序集及应用清单出现不同版本。

在有交互桌面的 Windows 机器上可额外运行：

```powershell
dotnet run --project windows/tests/DoubaoVoiceBridge.WindowsSmoke -c Release
```

该冒烟程序只向自己获得焦点的文本框发送 Ctrl+V，检查原生 INPUT 布局、Unicode 剪贴板及所有权恢复，不连接 UU、不启动豆包。运行期间不要操作键盘或切换焦点；不支持安全备份的原剪贴板会在修改前被拒绝。它仍不等同于端到端验收。

GitHub Actions 的 Windows 工作流会运行核心和原生冒烟测试，构建两种架构并保存工件；只有工作流实际通过后才构成 Windows CI 验证，ARM64 包仍需在 ARM64 实机验收。
