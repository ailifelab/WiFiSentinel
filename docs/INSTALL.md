本文由CODEX全自动编写。

# 安装、更新、卸载与回滚

## 下载并安装

当前正式包是 **0.1 / build 5.3，Apple Silicon（arm64）**。应用和 DMG 均已使用 Developer ID 正式签名、完成 Apple 公证与票据附加，并通过本机 Gatekeeper 检查。

最低编译目标为 macOS 13；本轮检查环境为 macOS 27.0.1，较早系统与 Intel 尚未实机验证。本次不提供 Intel 包。

1. 从[发行页面](https://github.com/ailifelab/WiFiSentinel/releases/tag/v0.1-build5.3)下载 DMG 与同名 `.sha256` 文件。两者放在同一目录后，可在终端用下面的命令核对完整性：

   ```sh
   shasum -a 256 -c WiFiSentinel-0.1-build5.3-macos-arm64.dmg.sha256
   ```

2. 双击 DMG，将 `WiFiSentinel.app` 拖到同一窗口的 `Applications` 入口。更新前请按下文先退出旧版、保留回滚副本。
3. 从“应用程序”打开哨兵，再推出磁盘映像。macOS 可能显示标准的首次打开确认，请核对来源与开发者后决定是否打开。正式签名开发者为 `Sherard Lee (75MD457NV7)`。无需关闭 Gatekeeper 或清除隔离属性。
4. 点击菜单栏的小眼睛 Wi-Fi 图标，在“状态与操作”查看当前结论。关闭主窗口后，应用仍留在菜单栏。
5. 自动恢复每次启动默认关闭，定期检测和异常日志仍可使用。需要时勾选“允许本次启动自动恢复”，在应用里阅读风险并确认。自动恢复或手动重联可能短暂关开 Wi-Fi，中断会议、下载、SSH 或 VPN。

读取当前 Wi-Fi 名称所需的定位授权由你在系统弹窗中决定。签名和公证不会自动授予定位、网络控制、辅助功能或管理员权限；应用不安装特权后台服务。没有定位授权时，请按应用提示使用，拒绝后不会反复申请。

本轮检查了包的签名、公证、Gatekeeper 与只读挂载内容，没有安装或启动该候选来中断已有监测。不同系统的首次安装与完整网络恢复仍需各自验证，详见[验证范围](VALIDATION.md)。

## 更新

1. 保留旧 `.app` 的完整副本，避免覆盖唯一可回滚版本。
2. 在旧应用菜单中正常退出。若提示 Wi-Fi 重新开启未确认，先到系统 Wi-Fi 菜单检查；不要强制结束正在恢复无线电开启状态的进程。
3. 确认旧应用已退出，再从新 DMG 将应用拖入自己的应用目录，替换旧副本，并从预期目录打开。
4. 检查界面和检测结果。替换期间会有短暂监测中断；新启动仍需重新确认自动恢复。

## 回滚

正常退出当前应用，再恢复保留的旧 `.app` 并启动。不要手动编辑恢复事务或冷却文件来完成回滚。旧版本若提示状态不兼容或无法核实，先按提示人工检查。

## 卸载与本地数据

先正常退出，并确认没有未完成的 Wi-Fi 重新开启责任，再将应用移到废纸篓。

设置、异常日志及恢复策略状态位于 `~/Library/Application Support/WiFiSentinel/`。需要保留时可做一份私密备份；不再需要时，可在应用退出且没有未完成事务后删除此目录。删除会一并移除设置和冷却记录。定位等系统权限由 macOS 管理，不需要修改系统权限数据库。

## 从源码运行

需要 Swift 5.9 或更新编译器的 Xcode Command Line Tools、Python 3 和 zsh。需要时运行 `xcode-select --install`，按系统提示安装开发工具，然后执行：

```sh
git clone https://github.com/ailifelab/WiFiSentinel.git
cd WiFiSentinel
/bin/zsh scripts/build.sh
open build/candidates/rewrite5-exit0/WiFiSentinel.app
```

构建结果位于 `build/candidates/rewrite5-exit0/WiFiSentinel.app`；准备长期使用时，正常退出后将它复制到自己的应用目录。自行构建的应用没有正式发行签名或公证，不等同于 Releases 的正式包。

开发者可按[验证说明](VALIDATION.md)运行离线检查；普通使用不需要安装任何本机验证辅助程序或后台服务。分发细节见[签名与分发说明](DISTRIBUTION.md)。
