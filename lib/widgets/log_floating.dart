import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/ble_engine.dart';

/// 悬浮日志窗口（全局置顶小窗）：
/// - 标题栏拖动移动；左上角 最大化/还原；右上角 关闭；
/// - 两个下角拖动 缩小/放大；内容可选中复制，标题栏有"复制全部"。
///
/// 从任意页面的三点菜单「悬浮日志」打开/关闭。
class FloatingLog {
  FloatingLog._();
  static final FloatingLog instance = FloatingLog._();

  OverlayEntry? _entry;

  bool get isShowing => _entry != null;

  /// 打开（已打开则先关掉再开，保证置顶）
  void show(BuildContext context) {
    hide();
    _entry = OverlayEntry(
      builder: (_) => const _FloatingLogWindow(),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void hide() {
    _entry?.remove();
    _entry = null;
  }

  /// 菜单点击入口：开着就关，关着就开
  void toggle(BuildContext context) {
    if (isShowing) {
      hide();
    } else {
      show(context);
    }
  }
}

class _FloatingLogWindow extends StatefulWidget {
  const _FloatingLogWindow();

  @override
  State<_FloatingLogWindow> createState() => _FloatingLogWindowState();
}

class _FloatingLogWindowState extends State<_FloatingLogWindow> {
  Offset _pos = const Offset(40, 120);
  Size _size = const Size(300, 380);
  bool _max = false;

  static const double _barH = 40;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final size = _max ? Size(screen.width - 16, screen.height - 80) : _size;
    final maxLeft = (screen.width - 120).clamp(0.0, double.infinity).toDouble();
    final maxTop = (screen.height - 80).clamp(0.0, double.infinity).toDouble();
    final left = _max ? 8.0 : _pos.dx.clamp(0.0, maxLeft).toDouble();
    final top = _max ? 60.0 : _pos.dy.clamp(0.0, maxTop).toDouble();

    return Positioned(
      left: left,
      top: top,
      width: size.width,
      height: size.height,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(10),
        shadowColor: Colors.black54,
        color: Colors.white,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFF57C00), width: 1.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              // ---- 标题栏：拖动 / 最大化 / 复制全部 / 关闭 ----
              GestureDetector(
                onPanUpdate: _max
                    ? null
                    : (d) => setState(() => _pos += d.delta),
                child: Container(
                  height: _barH,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF57C00),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(9)),
                  ),
                  child: Row(
                    children: [
                      // 左上角：最大化 / 还原
                      _barBtn(
                        _max ? Icons.fullscreen_exit : Icons.fullscreen,
                        _max ? '还原' : '最大化',
                        () => setState(() => _max = !_max),
                      ),
                      const Expanded(
                        child: Text('日志',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                      ),
                      _barBtn(Icons.copy, '复制全部', _copyAll),
                      // 右上角：关闭
                      _barBtn(Icons.close, '关闭', () => FloatingLog.instance.hide()),
                    ],
                  ),
                ),
              ),
              // ---- 内容：可选中复制 ----
              Expanded(
                child: ValueListenableBuilder<List<LogEntry>>(
                  valueListenable: BleEngine.instance.logs,
                  builder: (_, logs, __) {
                    // 只取最近 500 条，避免小窗渲染压力大
                    final list =
                        logs.length > 500 ? logs.sublist(logs.length - 500) : logs;
                    if (list.isEmpty) {
                      return const Center(
                          child: Text('暂无日志', style: TextStyle(color: Colors.grey)));
                    }
                    return SelectionArea(
                      child: ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 1),
                          child: Text(
                            _line(list[i]),
                            style: const TextStyle(
                                fontSize: 11,
                                height: 1.4,
                                fontFamily: 'monospace',
                                color: Colors.black87),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // ---- 底部：两个角 缩小 / 放大（拖拽改尺寸） ----
              if (!_max)
                SizedBox(
                  height: 20,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      GestureDetector(
                        onPanUpdate: (d) => setState(() {
                          _size = Size(
                            (_size.width - d.delta.dx)
                                .clamp(200.0, 620.0)
                                .toDouble(),
                            (_size.height - d.delta.dy)
                                .clamp(180.0, 800.0)
                                .toDouble(),
                          );
                        }),
                        child: const Icon(Icons.zoom_out_map,
                            size: 16, color: Colors.grey),
                      ),
                      const Text('拖角缩放', style: TextStyle(fontSize: 10, color: Colors.grey)),
                      GestureDetector(
                        onPanUpdate: (d) => setState(() {
                          _size = Size(
                            (_size.width + d.delta.dx)
                                .clamp(200.0, 620.0)
                                .toDouble(),
                            (_size.height + d.delta.dy)
                                .clamp(180.0, 800.0)
                                .toDouble(),
                          );
                        }),
                        child: const Icon(Icons.open_in_full,
                            size: 16, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barBtn(IconData icon, String tip, VoidCallback onTap) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 20, color: Colors.white),
      tooltip: tip,
      onPressed: onTap,
    );
  }

  String _line(LogEntry e) {
    if (e.dir == LogDir.event) return '${e.timeStr}> ${e.message ?? ''}';
    return '${e.timeStr}> [${e.tag}] ${e.dirStr} "${HexUtilLog.toHex(e.bytes)}"';
  }

  void _copyAll() {
    final logs = BleEngine.instance.logs.value;
    final sb = StringBuffer();
    for (final e in logs) {
      sb.writeln(_line(e));
    }
    Clipboard.setData(ClipboardData(text: sb.toString()));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已复制 ${logs.length} 条日志到剪贴板'),
        duration: const Duration(milliseconds: 800)));
  }
}

/// 独立的 hex 转换（避免引页面级依赖）
class HexUtilLog {
  static String toHex(List<int> bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
  }
}
