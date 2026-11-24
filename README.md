# BLE调试助手（Flutter 版）

硬件工程师日常用的安卓 BLE 调试工具。功能对标原版「BLE蓝牙助手 1.3.95」（去广告版），代码全部原创。

功能规格详见 [docs/功能规格.md](docs/功能规格.md)。
（旧的云编译入门笔记还在 `学习手册.md` / `GitHub操作笔记.md`，操作流程没变。）

## 现在能用的功能

- 🔍 **扫描页**：可用设备/活动连接双 Tab、名称/地址/UUID/RSSI 过滤、循环扫描、单次扫描周期设置
- 📱 **连接**：多设备同时连接、服务/特征值树形展示（已知 UUID 显示友好名）
- ✍️ **读写**：特征值读取、hex/ascii 写入、无响应写、通知开关
- 📜 **实时日志**：收发日志、关键字过滤、hex/ascii 切换、自动滚动、收发包计数
- 🚀 **发送栏**：发送历史、循环发送+延时、自定义按键面板
- 🎛 **自定义按键**：增删改、批量发送、剪贴板导入/导出（兼容原版 fast_cmds 格式）

## 编译方式

推送到 main 分支 → GitHub Actions 云编译 → Actions 页面下载 `bletool-debug-apk` → 拖到 `2-安装APK.bat` 安装。

## 目录结构

```
lib/
  main.dart            应用入口 + 橙色主题
  core/ble_util.dart   hex/ascii 解析、UUID 友好名映射
  models/models.dart   日志条目、自定义按键命令模型
  services/ble_engine.dart  BLE 引擎（扫描/连接/会话/日志）
  pages/
    scan_page.dart     扫描主页 + 过滤抽屉
    device_page.dart   设备详情（服务树/实时日志/发送栏）
    fast_cmd_page.dart 自定义按键
ci/AndroidManifest.xml CI 用 Manifest 模板（蓝牙权限）
```

## 后续排期（见功能规格）

收藏设备、扫码连接、广播数据图表页（RSSI 曲线 + AD 结构解析）、发送文件、日志落盘导出、外围模式（二期）。
