# 远控听写·自动适配（DoubaoVoiceBridge 社区 fork）

这是基于 [上游 DoubaoVoiceBridge](https://github.com/yupeng316888-create/DoubaoVoiceBridge) 开发的独立社区 fork，面向 macOS：当 UU 远控处于前台时，用豆包语音输入法识别本地语音，并通过 UU 剪贴板同步把文字放入远端输入框。本 fork 使用独立的 `0.1.0` 版本序列。

**直接下载：**[Fork Releases 最新版本](https://github.com/PengJunchen/DoubaoVoiceBridge/releases/latest)。首个 `v0.1.0` Release 尚未发布；该入口会指向最新 fork 预构建包。Release 由 GitHub Actions 构建，方便用户安装；它不是上游项目或 Apple 的官方发行，也没有 Apple Developer ID 签名或公证。

本 fork 对上游版本做了按键录制与交互改进：豆包键和远控触发键可分别录制；独立的自定义远控键采用明确的按住说话、松开结束语音并粘贴；设置首页突出当前操作，高级选项默认收起；剪贴板投递会先确认 UU 原窗口，处理同步等待与内容变化，并避免延迟恢复覆盖用户后来复制的内容。提交给上游的改进见 [PR #3](https://github.com/yupeng316888-create/DoubaoVoiceBridge/pull/3)，目前为 open，尚未合并。

本项目与豆包、字节跳动、UU 远控、网易及上游维护者均无隶属、合作或认可关系。相关名称和商标归各自权利人所有。fork 按 MIT 许可分发，保留原项目的 [MIT LICENSE](LICENSE) 及其中的上游版权声明；没有以本 fork 替换原许可声明。

## 安装与使用

从最新 [Fork Release](https://github.com/PengJunchen/DoubaoVoiceBridge/releases/latest) 下载 `DoubaoVoiceBridge-macOS-universal-vX.Y.Z.zip` 和对应 `.sha256` 文件。解压后将“远控听写·自动适配.app”移入“应用程序”。首次运行时，macOS 可能要求确认这个未公证的应用；请只在确认下载来源和校验和后继续。随后在“系统设置 → 隐私与安全性”中为应用开启辅助功能和输入监控权限。

要求 macOS 13 或更高版本、Intel 或 Apple Silicon Mac、豆包语音输入法，以及能正常连接并同步剪贴板的 UU 远控。打开应用后按设置窗口录制并保存按键；完成初始设置后，关闭窗口即可从菜单栏使用。独立的自定义远控键是长按方式：在 UU 中按住说话，松开结束并粘贴。只有明确选择“跟随豆包按键”时，远控触发键才沿用豆包的单击或长按方式。

本 fork 沿用上游的 Bundle ID 和本地设置身份，建议不要同时运行 fork 与上游版本，以免混淆权限或共享配置。

## 隐私与工作边界

本工具本身不录音、不调用豆包账号或语音服务，也不发起网络请求或保存听写正文。语音识别由豆包输入法处理；UU 负责远端连接和剪贴板同步。工具只在本机读取快捷键、与相关窗口交互，并把识别文字交给系统剪贴板。`--diagnostics` 只输出权限、进程和设置读取状态的摘要，不输出设置窗口正文。

远端粘贴没有 UU 接收回执；发送 Command-V 后应检查远端输入框。保存设置或通过内置自检不等于完成所有豆包版本和远控环境的真人验收。验证记录及其证据范围见 [剪贴板与长按验证](docs/validation/clipboard-and-hold-ui-2026-10-16.md)；其中记载的是历史 `2.6.4`（build 13）验证，不代表 fork `0.1.0` 已完成相同验收。

## 从源码构建

需要 Xcode Command Line Tools 和 Swift 5.9 或更高版本：

```bash
git clone https://github.com/PengJunchen/DoubaoVoiceBridge.git
cd DoubaoVoiceBridge
./scripts/build-app.sh
open dist
```

构建脚本生成 x86_64 与 arm64 通用 `.app`，执行 ad-hoc 签名、自检和只读诊断。该包没有 Apple Developer ID 签名，也未经过公证。可运行 `swift run DoubaoVoiceBridge --self-test` 查看内置自检；从终端运行 `--diagnostics` 只反映该次命令行上下文的权限，不代表图形应用已获得授权。

fork 的发版流程、`vX.Y.Z` tag 规则和手动 dry-run 说明见 [docs/fork-releases.md](docs/fork-releases.md)。许可证见 [LICENSE](LICENSE)。
