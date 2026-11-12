# 你好Demo（Flutter 云端编译闭环练习）

一个最小可用的 Flutter 工程，用来跑通「改代码 → 云端编译 → 装手机 → 看日志」的完整闭环。
**本机不需要安装 Flutter / Android SDK。**

## 一、闭环流程

| 步骤 | 你要做什么 | 在哪做 |
|---|---|---|
| 1 | 改 `lib/main.dart` 里的文字 | 本机（用记事本/VSCode 都行） |
| 2 | 提交并推送到 GitHub | 本机 |
| 3 | 等云端编译（约 3~8 分钟） | GitHub 网页 → Actions |
| 4 | 下载 APK | GitHub 网页 → Actions → 本次运行 → Artifacts |
| 5 | 装到手机上 | 把 APK 拖到 `2-安装APK.bat` 上 |
| 6 | 看日志 | 双击 `1-查看日志.bat` |

## 二、手机上要开的开关

1. 设置 → 关于手机 → 连续点「版本号」7 次，开启开发者选项
2. 开发者选项 → 打开「USB 调试」（有的品牌还要开「USB 安装」）
3. 用数据线连电脑，手机上弹窗选「允许」

## 三、这个 Demo 里已经埋好的验证点

- 界面显示大字「欢迎使用」 → 验证 APK 能装能跑
- 启动时打印 `=== 你好Demo 启动成功 ===` → 验证日志链路
- 每秒打印一次 `心跳 N 次，运行中...` → 验证实时日志
- 点按钮打印时间戳 → 验证交互日志

## 四、编译配置

`.github/workflows/build-apk.yml` 已写好：推送到 `main` 分支自动编译 Debug APK 并上传。
也可以在网页 Actions 页面点「Run workflow」手动触发。

## 五、为什么用 Debug 包

Debug 包带完整日志输出，`adb logcat` 能看到 App 里 `debugPrint/print` 的所有内容。
正式用的时候在 workflow 里把 `--debug` 改成 `--release` 即可。
