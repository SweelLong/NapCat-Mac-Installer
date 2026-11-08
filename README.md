# NapCat-Mac-Installer

macOS 12+ 的 NapCat 安装和更新工具，支持 Intel / Apple Silicon。

## 使用

1. 将 QQ 安装到 `/Applications/QQ.app`。
2. 下载并打开 [安装器](https://github.com/NapNeko/NapCat-Mac-Installer/releases/latest)，选择 NapCat 版本和下载方式，点击安装。
3. 按提示备份并修改 QQ 入口，选择「切换程序入口 NapCat」，然后启动。
4. 恢复原版时选择「切换程序入口 原版 QQ」。

入口修改被系统拒绝时，在「系统设置 → 隐私与安全性 → App 管理」中允许安装器管理 QQ。

首次运行若提示需要授权访问 QQ 数据目录，点击「授权访问」，在面板中点击「授权」即可。

配置和插件位于 `~/Library/Containers/com.tencent.qq/Data/Documents/napcat`，更新时保留。

## 同时运行 NapCat 与原版 QQ

切换到 NapCat 入口后，启动管理面板每 2 秒读取一次实际进程，显示 NapCat 与原版 QQ 的运行状态、PID 和窗口状态。两者可以同时运行，互不结束对方：

| 按钮 | 行为 |
| --- | --- |
| 启动 NapCat | 在新的终端窗口中以 `--no-sandbox` 启动；NapCat 已在运行时不重复启动，不会结束原版 QQ |
| 启动 / 显示 原版QQ | 以新实例（`open -n`）打开原版 QQ 图形界面；已有原版实例时激活它，不重复创建 |
| 停止 | 确认后只结束所选的那个实例：先请求正常退出，10 秒无响应才发送 SIGTERM，不使用 SIGKILL |

使用方法：

1. 按上面的步骤安装 NapCat，并选择「切换程序入口 NapCat」。
2. 点击「启动 NapCat」，按 NapCat 的提示登录机器人账号。
3. 点击「启动 原版QQ」，在图形界面中登录**另一个** QQ 账号。

注意事项：

- 两个实例必须使用不同的 QQ 账号。
- 两者共用 `~/Library/Containers/com.tencent.qq/Data`（包括 `global/nt_db/login.db` 和 mmkv 数据）。测试中没有发现冲突，但长时间同时运行的稳定性尚未充分验证。
- `loadNapCat.js` 缺失或为旧版时，会在启动时自动生成；自定义内容不会被覆盖。
- QQ 热更新生成新版本后，「启动 NapCat」会自动把新热更新包的入口指向 NapCat。

## 构建

使用 Xcode 打开 `NapCatInstaller.xcodeproj`，选择 `NapCatInstaller` scheme 构建。CI 提供 universal 安装包。

[使用文档](https://napneko.github.io/guide/boot/Shell#macos)

## 许可证 / License

MIT，见 [LICENSE](LICENSE)。Copyright (c) 2024 NapNeko.
