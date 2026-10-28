# 远控听写·自动适配

这是 [DoubaoVoiceBridge 上游项目](https://github.com/yupeng316888-create/DoubaoVoiceBridge) 的独立 fork 迭代分支，版本从 [v0.1.0](CHANGELOG.md) 开始。它面向 macOS：在 UU 远控中使用豆包语音输入法识别文字，再通过 UU 剪贴板同步粘贴到远端。

## Fork 改进

- 豆包语音键与远控触发键可分别录制。
- 设置按当前模式显示操作提示；独立远控键按住说话、松开结束，界面采用暖灰蓝配色和简洁布局。
- 投递前确认 UU 窗口，并保护用户后来复制的剪贴板内容。

向上游提交的改进见 [PR #3](https://github.com/yupeng316888-create/DoubaoVoiceBridge/pull/3)，尚未合并。

## 使用

需要 macOS 13 或更高版本、已启用的豆包语音输入法，以及可同步剪贴板的 UU 远控。

1. 从 [Fork Releases 最新版本](https://github.com/PengJunchen/DoubaoVoiceBridge/releases/latest) 下载 `.app` ZIP 和 SHA-256 校验文件；Apple Silicon/M 系列选 arm64，Intel 选 x86_64，不确定时选通用版，校验后解压并将应用移入“应用程序”打开。
2. 应用采用 ad-hoc 签名，未经过 Apple 公证；首次打开时按 macOS 提示确认，并为应用开启辅助功能和输入监控权限。
3. 打开设置，在高级设置中分别录制豆包键和远控键，选择与豆包一致的启动方式并保存。
4. 先点选远端输入框，再在 UU 中按住独立远控键说话，松开后结束听写并粘贴。选择“跟随豆包按键”时，远控操作沿用豆包的单击或长按方式。

本工具只粘贴文字，不替用户向远端发送消息。

## Windows 预验证版

Windows 实现位于 `windows/`，与现有 Swift/macOS 应用独立构建。它沿用「本机豆包听写框 → UU 剪贴板同步 → 原会话粘贴」流程，提供托盘设置、专用触发键、按住/切换语音模式、粘贴测试及脱敏诊断导出。

首次使用请保留手动启动豆包与手动确认粘贴，完成实机验收后再开启模拟快捷键和自动粘贴。当前环境已完成的验证及尚待 Windows 实机确认的部分见 [Windows 验证记录](docs/windows/validation.md)。安装、构建与日志回传见 [Windows 使用说明](windows/README.md)，方案依据见 [Windows 架构与可行性](docs/windows/architecture.md)。

## 构建

需要 Xcode Command Line Tools 和 Swift 5.9 或更高版本：

```bash
git clone https://github.com/PengJunchen/DoubaoVoiceBridge.git
cd DoubaoVoiceBridge
./scripts/build-app.sh
```

构建输出为 `dist/远控听写·自动适配.app`，包含 x86_64 与 arm64 通用二进制。发版与 dry-run 说明见 [docs/fork-releases.md](docs/fork-releases.md)。

## 许可证

本 fork 按 [MIT 许可证](LICENSE) 分发，并保留原项目版权声明。
