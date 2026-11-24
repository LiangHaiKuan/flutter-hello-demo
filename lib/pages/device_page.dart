import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../core/ble_util.dart';
import '../models/models.dart';
import '../services/ble_engine.dart';
import '../widgets/log_floating.dart';
import 'fast_cmd_page.dart';
import 'knowledge_page.dart';

/// 设备详情页：蓝牙服务 / 实时日志
class DevicePage extends StatefulWidget {
  final String mac;
  final String name;
  const DevicePage({super.key, required this.mac, required this.name});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  final BleEngine _engine = BleEngine.instance;
  DeviceSession? _session;
  TextCodec _codec = TextCodec.hex; // 发送/日志显示编码（hex/ascii/utf8/gbk）
  bool _translate = false; // 接收区 hex→文本翻译（点一下更新一次）
  DateTime? _translateSnapshot; // 翻译只作用于点击时刻之前的日志
  _WriteType _writeType = _WriteType.defaultWrite;
  bool _loopSend = false;
  final TextEditingController _sendCtl = TextEditingController();
  final TextEditingController _delayCtl = TextEditingController(text: '10');
  final TextEditingController _filterCtl = TextEditingController();
  final ScrollController _logScroll = ScrollController();
  Timer? _loopTimer;

  @override
  void initState() {
    super.initState();
    _session = _engine.sessionOf(widget.mac);
    _engine.sessionsBump.addListener(_onSessionsChanged);
    _session?.state.addListener(_onSessionsChanged);
  }

  void _onSessionsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _engine.sessionsBump.removeListener(_onSessionsChanged);
    _session?.state.removeListener(_onSessionsChanged);
    _loopTimer?.cancel();
    _sendCtl.dispose();
    _delayCtl.dispose();
    _filterCtl.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  DeviceSession get session {
    _session ??= _engine.sessionOf(widget.mac);
    return _session!;
  }

  // ---------- 发送 ----------
  Future<void> _sendOnce() async {
    final text = _sendCtl.text;
    final bytes = HexUtil.parse(text, _codec);
    if (bytes == null) {
      _toast('数据格式错误');
      return;
    }
    if (session.targetChar.value == null) {
      _toast('请先在蓝牙服务页选择一个可写特征值');
      return;
    }
    if (!session.isConnected) {
      _toast('设备未连接');
      return;
    }
    final withoutResponse = _writeType == _WriteType.noResponse;
    await session.send(bytes, withoutResponse);
  }

  void _toggleLoop(bool? v) {
    setState(() => _loopSend = v ?? false);
    _loopTimer?.cancel();
    if (_loopSend) {
      final delay = int.tryParse(_delayCtl.text) ?? 10;
      _loopTimer = Timer.periodic(
          Duration(milliseconds: delay.clamp(1, 10000)), (_) => _sendOnce());
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(milliseconds: 800)));
  }

  /// hex 翻译开关：点一下翻译当前日志，再点还原；新收数据不自动翻译
  void _setTranslate(bool v) {
    setState(() {
      _translate = v;
      if (v) {
        _translateSnapshot = DateTime.now();
      } else {
        _translateSnapshot = null;
      }
    });
  }

  // ---------- 特征值操作 ----------
  /// 上传图标 = 发送通道开关：点一下把该特征设为发送目标（点亮），再点一下取消。
  /// 数据从底部发送栏发出（第二个方法：底部"未选特征"文字按钮，保留）。
  void _toggleTarget(BluetoothCharacteristic c) {
    if (session.targetChar.value?.uuid.str == c.uuid.str) {
      session.targetChar.value = null;
    } else {
      session.targetChar.value = c;
    }
  }

  void _pickTargetChar() {
    final writable = <BluetoothCharacteristic>[];
    for (final s in session.services) {
      for (final c in s.characteristics) {
        if (c.properties.write || c.properties.writeWithoutResponse) {
          writable.add(c);
        }
      }
    }
    if (writable.isEmpty) {
      _toast('没有可写特征值');
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('选择发送目标特征值',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final c in writable)
              ListTile(
                title: Text(UuidNames.charName(c.uuid.str)),
                subtitle: Text(shortUuid(c.uuid.str)),
                trailing: session.targetChar.value?.uuid.str == c.uuid.str
                    ? const Icon(Icons.check, color: Color(0xFFF57C00))
                    : null,
                onTap: () {
                  session.targetChar.value = c;
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showHistory() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => ValueListenableBuilder<List<String>>(
        valueListenable: session.writeHistory,
        builder: (_, hist, __) => SafeArea(
          child: hist.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: Text('暂无发送历史')),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('发送历史（点击填入输入框）',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    for (final h in hist)
                      ListTile(
                        dense: true,
                        title: Text(h,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 13)),
                        onTap: () {
                          _sendCtl.text = h.replaceAll(' ', '');
                          Navigator.pop(ctx);
                        },
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  void _showFastCmdSheet() {
    final engine = BleEngine.instance;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => ValueListenableBuilder<int>(
        valueListenable: engine.cmdsBump,
        builder: (_, __, ___) => SafeArea(
          child: engine.cmds.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Center(child: Text('暂无自定义按键')),
                      TextButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const FastCmdPage()));
                          },
                          child: const Text('去添加')),
                    ],
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('自定义按键（点击发送）',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.edit,
                          color: Color(0xFFF57C00)),
                      title: const Text('编辑命令（增删改 / 导入导出 / 云端）'),
                      onTap: () {
                        Navigator.pop(ctx);
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const FastCmdPage()));
                      },
                    ),
                    for (final c in engine.cmds.where((c) => c.enabled))
                      ListTile(
                        dense: true,
                        title: Text(c.name),
                        subtitle: Text(c.preview(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 12)),
                        onTap: () async {
                          final bytes = HexUtil.parse(c.data,
                              c.hexMode ? TextCodec.hex : TextCodec.ascii);
                          if (bytes == null) {
                            _toast('命令数据格式错误: ${c.name}');
                            return;
                          }
                          await session.send(bytes, false);
                        },
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  // ================= 退出（返回键两选一） =================

  Future<bool> _confirmExit() async {
    // 未连接：直接退出，不弹窗
    if (!session.isConnected) return true;
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出设备页面'),
        content: const Text('设备仍处于连接状态，要怎么处理？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'stay'),
              child: const Text('仅返回界面（保持连接）')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, 'disconnect'),
              child: const Text('断开并退出')),
        ],
      ),
    );
    if (res == 'disconnect') {
      await session.disconnect();
      return true;
    }
    if (res == 'stay') return true;
    return false;
  }

  // ================= AppBar 更多菜单 =================

  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.file_download, color: Color(0xFFF57C00)),
              title: const Text('导出日志'),
              onTap: () {
                Navigator.pop(ctx);
                _exportLogsToFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.share, color: Color(0xFFF57C00)),
              title: const Text('分享日志'),
              onTap: () {
                Navigator.pop(ctx);
                _shareLogs();
              },
            ),
            ListTile(
              leading: const Icon(Icons.tune, color: Color(0xFFF57C00)),
              title: const Text('日志格式设置'),
              subtitle: const Text('时间 / [主题] / 动作文字 / 引号 可配置'),
              onTap: () {
                Navigator.pop(ctx);
                _showLogFormatDialog();
              },
            ),
            ValueListenableBuilder<int>(
              valueListenable: session.statsBump, // mtu 变化时借 statsBump 刷新
              builder: (_, __, ___) => ListTile(
                leading: const Icon(Icons.settings_ethernet, color: Color(0xFFF57C00)),
                title: Text(session.mtu > 0
                    ? '修改MTU (当前${session.mtu})'
                    : '修改MTU (512)'),
                onTap: () {
                  Navigator.pop(ctx);
                  _requestMtu();
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file, color: Color(0xFFF57C00)),
              title: const Text('传送文件'),
              onTap: () {
                Navigator.pop(ctx);
                _sendFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.menu_book, color: Color(0xFFF57C00)),
              title: const Text('蓝牙服务科普'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            KnowledgePage(section: 'gatt', name: widget.name)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.bolt, color: Color(0xFFF57C00)),
              title: const Text('自定义按钮'),
              subtitle: const Text('命令编辑 / 导入导出 / 云端同步'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const FastCmdPage()));
              },
            ),
            // 翻译开关（从日志工具栏挪过来，避免把那行撑出溢出警告）
            ListTile(
              leading: const Icon(Icons.translate, color: Color(0xFFF57C00)),
              title: const Text('hex翻译（接收区）'),
              subtitle: Text(_translate
                  ? '已开启：hex 解析成文本（再点还原，新数据不自动翻）'
                  : '仅 hex 格式下可用，点一下翻译当前日志'),
              trailing: Switch(
                value: _translate && _codec == TextCodec.hex,
                activeColor: const Color(0xFFF57C00),
                onChanged: (v) {
                  Navigator.pop(ctx);
                  _setTranslate(v);
                },
              ),
              onTap: () {
                Navigator.pop(ctx);
                _setTranslate(!_translate);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.picture_in_picture,
                color: FloatingLog.instance.isShowing
                    ? Colors.green
                    : const Color(0xFFF57C00),
              ),
              title: const Text('悬浮日志'),
              subtitle: const Text('置顶小窗：可拖动/缩放/最大化/复制'),
              onTap: () {
                Navigator.pop(ctx);
                FloatingLog.instance.toggle(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 日志格式设置（编辑按钮） ----------
  void _showLogFormatDialog() {
    final e = _engine;
    showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('日志格式设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('行结构：时间> [主题] 动作: "数据"',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('显示时间（16:17:47.956>）'),
                value: e.logShowTime,
                activeColor: const Color(0xFFF57C00),
                onChanged: (v) => setD(() => e.logShowTime = v ?? true),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('显示 [发送主题]（特征值UUID缩写）'),
                value: e.logShowTag,
                activeColor: const Color(0xFFF57C00),
                onChanged: (v) => setD(() => e.logShowTag = v ?? true),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('显示动作文字（成功写入:/Notify:）'),
                value: e.logShowDir,
                activeColor: const Color(0xFFF57C00),
                onChanged: (v) => setD(() => e.logShowDir = v ?? true),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('数据用引号包裹（"FF 55 AA"）'),
                value: e.logShowQuote,
                activeColor: const Color(0xFFF57C00),
                onChanged: (v) => setD(() => e.logShowQuote = v ?? true),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    e.saveLogFormat();
    setState(() {});
  }

  // ---------- 导出/分享日志（落盘，按用户配置的行格式） ----------
  String _buildLogText() {
    final e2 = _engine;
    final sb = StringBuffer();
    for (final e in e2.logs.value) {
      if (e.dir == LogDir.event) {
        sb.writeln('${e.timeStr}> ${e.message ?? ''}');
      } else {
        sb.writeln(_LogLine.format(e, TextCodec.hex,
            showTime: e2.logShowTime,
            showTag: e2.logShowTag,
            showDir: e2.logShowDir,
            showQuote: e2.logShowQuote));
      }
    }
    return sb.toString();
  }

  Future<void> _exportLogsToFile() async {
    try {
      final text = _buildLogText();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = await FilePicker.platform.saveFile(
        fileName: 'ble_log_$ts.txt',
        bytes: Uint8List.fromList(utf8.encode(text)),
      );
      if (path != null) {
        _toast('日志已保存到 $path');
      }
    } catch (e) {
      _toast('导出失败: $e');
    }
  }

  Future<void> _shareLogs() async {
    final text = _buildLogText();
    if (text.isEmpty) {
      _toast('暂无日志');
      return;
    }
    await Share.share(text, subject: 'BLE调试助手日志-${widget.name}');
  }

  // ---------- MTU ----------
  Future<void> _requestMtu() async {
    try {
      final m = await session.device.requestMtu(512);
      session.mtu = m;
      session.statsBump.value++;
      _toast('MTU 已协商为 $m');
      _engine.logEvent(widget.mac, 'MTU 协商为 $m');
    } catch (e) {
      _toast('修改 MTU 失败: $e');
    }
  }

  // ---------- 传送文件 ----------
  Future<void> _sendFile() async {
    if (!session.isConnected) {
      _toast('设备未连接');
      return;
    }
    try {
      final res = await FilePicker.platform.pickFiles(withData: true);
      if (res == null || res.files.isEmpty) return;
      final bytes = res.files.single.bytes;
      final fname = res.files.single.name;
      if (bytes == null || bytes.isEmpty) {
        _toast('无法读取所选文件');
        return;
      }
      // 按 MTU 分包发送（单包 = MTU - 3，至少 20）
      final chunkSize = session.mtu > 3 ? session.mtu - 3 : 20;
      final progress = ValueNotifier(0.0);
      final progressText = ValueNotifier('0 / ${bytes.length} 字节');
      var fail = 0;
      var cancelled = false;
      // 单个进度弹窗，通过 ValueNotifier 刷新
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('传送文件中...'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(fname),
                const SizedBox(height: 10),
                ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder: (_, v, __) =>
                      LinearProgressIndicator(value: v),
                ),
                const SizedBox(height: 6),
                ValueListenableBuilder<String>(
                  valueListenable: progressText,
                  builder: (_, t, __) => Text(t),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () {
                    cancelled = true;
                    Navigator.pop(ctx);
                  },
                  child: const Text('取消')),
            ],
          ),
        ),
      );
      var done = 0;
      for (var i = 0; i < bytes.length; i += chunkSize) {
        if (cancelled) break;
        final end =
            (i + chunkSize) > bytes.length ? bytes.length : i + chunkSize;
        final chunk = bytes.sublist(i, end);
        final ok = await session.send(chunk, true, recordHistory: false);
        if (!ok) {
          fail++;
          break;
        }
        done = end;
        progress.value = done / bytes.length;
        progressText.value = '$done / ${bytes.length} 字节  失败:$fail';
        await Future.delayed(const Duration(milliseconds: 15));
      }
      progress.dispose();
      progressText.dispose();
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _engine.logEvent(widget.mac,
          '文件传送完成: $fname 共${bytes.length}字节 成功$done 失败$fail');
      _toast('传送完成: 成功 $done 字节, 失败 $fail 包');
    } catch (e) {
      _toast('传送失败: $e');
    }
  }

  // ---------- 构建 ----------
  @override
  Widget build(BuildContext context) {
    final s = _engine.sessionOf(widget.mac);
    if (s == null) {
      // 理论上不会进来（会话断开后保留）；兜底显示
      return Scaffold(
        appBar: AppBar(title: const Text('BLE调试助手')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('设备未连接或连接已断开',
                  style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await _confirmExit();
        if (ok && context.mounted) Navigator.of(context).pop();
      },
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            leading: BackButton(
                onPressed: () async {
                  final ok = await _confirmExit();
                  if (ok && context.mounted) Navigator.of(context).pop();
                }),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.name,
                    style: const TextStyle(fontSize: 17, color: Colors.white)),
                Text(widget.mac,
                    style: const TextStyle(fontSize: 11, color: Colors.white70)),
              ],
            ),
            actions: [
              // 断开 / 回连 原地切换（不跳转）
              ValueListenableBuilder<BluetoothConnectionState>(
                valueListenable: s.state,
                builder: (_, st, __) {
                  final connected = st == BluetoothConnectionState.connected;
                  final connecting = st == BluetoothConnectionState.connecting;
                  if (connecting) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Center(
                          child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))),
                    );
                  }
                  return TextButton(
                    onPressed: () async {
                      if (connected) {
                        await session.disconnect();
                      } else {
                        _engine.connect(session.device);
                      }
                    },
                    child: Text(
                      connected ? '断开' : '回连',
                      style: const TextStyle(color: Colors.white),
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.more_vert, color: Colors.white),
                tooltip: '更多',
                onPressed: _showMoreMenu,
              ),
            ],
            bottom: const TabBar(
              indicatorColor: Colors.white,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              tabs: [Tab(text: '蓝牙服务'), Tab(text: '实时日志')],
            ),
          ),
          // 断开时整体变灰且不可操作
          body: ValueListenableBuilder<BluetoothConnectionState>(
            valueListenable: s.state,
            builder: (_, st, __) {
              final connected = st == BluetoothConnectionState.connected;
              return IgnorePointer(
                ignoring: !connected,
                child: AnimatedOpacity(
                  opacity: connected ? 1.0 : 0.45,
                  duration: const Duration(milliseconds: 200),
                  child: Stack(
                    children: [
                      TabBarView(
                        children: [
                          _ServicesTab(
                            session: session,
                            onToggleTarget: _toggleTarget,
                            onRead: session.readChar,
                            onNotifyToggle: _toggleNotify,
                            onPickTarget: _pickTargetChar,
                          ),
                          _LogTab(
                            session: session,
                            codec: _codec,
                            translate: _translate,
                            translateSnapshot: _translateSnapshot,
                            filterCtl: _filterCtl,
                            logScroll: _logScroll,
                            onFormat: (v) => setState(() => _codec = v),
                            onTranslate: () => _setTranslate(!_translate),
                          ),
                        ],
                      ),
                      if (!connected)
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 12),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('设备未连接',
                                    style: TextStyle(
                                        color: Colors.white, fontSize: 15)),
                                const SizedBox(height: 8),
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white),
                                  onPressed: () =>
                                      _engine.connect(session.device),
                                  child: const Text('回连'),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          bottomNavigationBar: _buildSendBar(),
        ),
      ),
    );
  }

  Future<void> _toggleNotify(BluetoothCharacteristic c, bool v) async {
    await session.setNotify(c, v);
  }

  Widget _buildSendBar() {
    return ValueListenableBuilder<BluetoothConnectionState>(
      valueListenable: session.state,
      builder: (_, st, __) {
        final connected = st == BluetoothConnectionState.connected;
        return IgnorePointer(
          ignoring: !connected,
          child: Opacity(
            opacity: connected ? 1.0 : 0.45,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  color: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _sendCtl,
                          enabled: connected,
                          style: const TextStyle(fontSize: 14),
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '数据格式: aa00bb11cc22（支持空格）',
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF57C00),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(56, 36),
                        ),
                        onPressed: connected ? _sendOnce : null,
                        child: const Text('发送'),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => setState(() {}),
                        child: const Icon(Icons.keyboard_double_arrow_down,
                            color: Color(0xFFF57C00)),
                      ),
                    ],
                  ),
                ),
                Container(
                  color: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _iconBtn(Icons.history, '发送历史', _showHistory),
                          const SizedBox(width: 12),
                          _iconBtn(Icons.bolt, '自定义按键', _showFastCmdSheet),
                          const SizedBox(width: 12),
                          DropdownButton<TextCodec>(
                            value: _codec,
                            underline: const SizedBox.shrink(),
                            items: TextCodec.values
                                .map((c) => DropdownMenuItem(
                                    value: c, child: Text(c.label)))
                                .toList(),
                            onChanged: (v) =>
                                setState(() => _codec = v ?? TextCodec.hex),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: _pickTargetChar,
                            child: ValueListenableBuilder<
                                BluetoothCharacteristic?>(
                              valueListenable: session.targetChar,
                              builder: (_, c, __) => Text(
                                c == null
                                    ? '未选特征'
                                    : '${shortUuid(c.uuid.str)}(${c.properties.writeWithoutResponse ? '无响应' : '默认'})',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 2,
                        children: [
                          _typeChip('Default', _WriteType.defaultWrite),
                          _typeChip('No Response', _WriteType.noResponse),
                          _typeChip('Signed', _WriteType.signed),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 24,
                                height: 24,
                                child: Checkbox(
                                  value: _loopSend,
                                  activeColor: const Color(0xFFF57C00),
                                  onChanged: _toggleLoop,
                                ),
                              ),
                              const Text('循环',
                                  style: TextStyle(fontSize: 12)),
                            ],
                          ),
                          const Text('延时(ms):',
                              style: TextStyle(fontSize: 12)),
                          SizedBox(
                            width: 46,
                            child: TextField(
                              controller: _delayCtl,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              style: const TextStyle(fontSize: 12),
                              decoration: const InputDecoration(
                                  isDense: true,
                                  border: UnderlineInputBorder()),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Tooltip(
        message: tip,
        child: Icon(icon, color: const Color(0xFFF57C00), size: 22),
      ),
    );
  }

  Widget _typeChip(String label, _WriteType t) {
    final selected = _writeType == t;
    return GestureDetector(
      onTap: () {
        setState(() {
          _writeType = t;
          if (t == _WriteType.signed) {
            _toast('Signed 签名写暂不支持，按默认方式发送');
            _writeType = _WriteType.defaultWrite;
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF57C00) : Colors.grey.shade300,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style:
                TextStyle(fontSize: 12, color: selected ? Colors.white : Colors.black54)),
      ),
    );
  }
}

enum _WriteType { defaultWrite, noResponse, signed }

// ---------------- 蓝牙服务 Tab（SelectionArea：长按任意文字可复制；展开状态记忆） ----------------
class _ServicesTab extends StatefulWidget {
  final DeviceSession session;
  final void Function(BluetoothCharacteristic) onToggleTarget;
  final Future<void> Function(BluetoothCharacteristic) onRead;
  final Future<void> Function(BluetoothCharacteristic, bool) onNotifyToggle;
  final VoidCallback onPickTarget;

  const _ServicesTab({
    required this.session,
    required this.onToggleTarget,
    required this.onRead,
    required this.onNotifyToggle,
    required this.onPickTarget,
  });

  @override
  State<_ServicesTab> createState() => _ServicesTabState();
}

class _ServicesTabState extends State<_ServicesTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // Tab 切换不重建（修复切换卡顿）

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final session = widget.session;
    return SelectionArea(
      // 长按任意文字（标题/UUID/属性）都可选中复制，中文菜单
      child: ValueListenableBuilder<bool>(
        valueListenable: session.servicesReady,
        builder: (_, ready, __) {
          if (!ready) {
            return ValueListenableBuilder<BluetoothConnectionState>(
              valueListenable: session.state,
              builder: (_, s, ___) => Center(
                child: Text(
                  s == BluetoothConnectionState.connected
                      ? '正在发现服务...'
                      : '连接中...',
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            );
          }
          return ValueListenableBuilder<BluetoothCharacteristic?>(
            valueListenable: session.targetChar,
            builder: (_, target, __) => ListView.builder(
              itemCount: session.services.length,
              itemBuilder: (_, i) {
                final svc = session.services[i];
                final uuidStr = svc.uuid.str;
                final expanded =
                    session.expandedServices.contains(uuidStr);
                return Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    key: ValueKey('svc_$uuidStr'),
                    initiallyExpanded: expanded,
                    tilePadding:
                        const EdgeInsets.symmetric(horizontal: 16),
                    childrenPadding:
                        const EdgeInsets.only(left: 16, bottom: 8),
                    onExpansionChanged: (v) {
                      // 记忆展开状态：返回本页时保持
                      setState(() {
                        if (v) {
                          session.expandedServices.add(uuidStr);
                        } else {
                          session.expandedServices.remove(uuidStr);
                        }
                      });
                    },
                    title: Text(
                      UuidNames.serviceName(uuidStr),
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87),
                    ),
                    subtitle: Text('UUID: ${uuidStr.toLowerCase()}',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.grey)),
                    children: [
                      for (final c in svc.characteristics)
                        _CharTile(
                          session: session,
                          char: c,
                          onToggleTarget: () => widget.onToggleTarget(c),
                          onRead: () => widget.onRead(c),
                          onNotifyToggle: (v) =>
                              widget.onNotifyToggle(c, v),
                          isTarget: target?.uuid.str == c.uuid.str,
                          onPickTarget: () {
                            // 最新点击为准：旧目标自动取消点亮
                            session.targetChar.value = c;
                          },
                        ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _CharTile extends StatelessWidget {
  final DeviceSession session;
  final BluetoothCharacteristic char;
  final VoidCallback onToggleTarget;
  final VoidCallback onRead;
  final VoidCallback onPickTarget;
  final Future<void> Function(bool) onNotifyToggle;
  final bool isTarget;

  const _CharTile({
    required this.session,
    required this.char,
    required this.onToggleTarget,
    required this.onRead,
    required this.onNotifyToggle,
    required this.onPickTarget,
    required this.isTarget,
  });

  String get _props {
    final p = char.properties;
    final list = <String>[];
    if (p.read) list.add('READ');
    if (p.write) list.add('WRITE');
    if (p.writeWithoutResponse) list.add('WRITE_NO_RESPONSE');
    if (p.notify) list.add('NOTIFY');
    if (p.indicate) list.add('INDICATE');
    return list.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final writable = char.properties.write ||
        char.properties.writeWithoutResponse;
    final notifiable = char.properties.notify ||
        char.properties.indicate;
    final readable = char.properties.read;
    final s = session;

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Expanded(
            child: Text(
              UuidNames.charName(char.uuid.str),
              style: const TextStyle(fontSize: 14, color: Colors.black87),
            ),
          ),
          if (isTarget)
            const Text('发送目标',
                style: TextStyle(
                    fontSize: 10, color: Color(0xFFF57C00))),
        ],
      ),
      subtitle: Text(
        'UUID: ${char.uuid.str.toLowerCase()}\nProperties: $_props',
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (writable)
            IconButton(
              // 发送通道开关：当前是发送目标 → 点亮（填充橙色），再点一下取消
              icon: Icon(
                isTarget ? Icons.upload : Icons.upload_outlined,
                color: isTarget
                    ? const Color(0xFFF57C00)
                    : Colors.grey,
                size: 20,
              ),
              tooltip: isTarget
                  ? '取消发送通道（点一下取消点亮）'
                  : '设为发送通道（点一下点亮，再点取消）',
              onPressed: onToggleTarget,
            ),
          if (readable)
            IconButton(
              icon: const Icon(Icons.download,
                  color: Color(0xFF4CAF50), size: 20),
              tooltip: '读取',
              onPressed: onRead,
            ),
          if (notifiable)
            // ValueListenableBuilder：点铃铛立即点亮/熄灭，不用刷新页面
            ValueListenableBuilder<int>(
              valueListenable: s.notifyBump,
              builder: (_, __, ___) {
                final on =
                    s.notifyState[char.uuid.str.toLowerCase()] ?? false;
                return IconButton(
                  icon: Icon(
                    on ? Icons.notifications_active : Icons.notifications_none,
                    color: on ? const Color(0xFFF57C00) : Colors.grey,
                    size: 20,
                  ),
                  tooltip: on ? '关闭通知' : '开启通知',
                  onPressed: () => onNotifyToggle(!on),
                );
              },
            ),
        ],
      ),
    );
  }
}

// ---------------- 实时日志 Tab（暂停/清屏/清零/长按导出/导出到文件/hex翻译/格式配置） ----------------
class _LogTab extends StatefulWidget {
  final DeviceSession session;
  final TextCodec codec;
  final bool translate;
  final DateTime? translateSnapshot;
  final TextEditingController filterCtl;
  final ScrollController logScroll;
  final ValueChanged<TextCodec> onFormat;
  final VoidCallback onTranslate;

  const _LogTab({
    required this.session,
    required this.codec,
    required this.translate,
    required this.translateSnapshot,
    required this.filterCtl,
    required this.logScroll,
    required this.onFormat,
    required this.onTranslate,
  });

  @override
  State<_LogTab> createState() => _LogTabState();
}

class _LogTabState extends State<_LogTab> with AutomaticKeepAliveClientMixin {
  bool _autoScroll = true;
  bool _showSend = true;
  bool _paused = false;
  List<LogEntry> _pausedList = [];

  @override
  bool get wantKeepAlive => true; // Tab 切换不重建（修复切换卡顿）

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final engine = BleEngine.instance;
    final session = widget.session;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            controller: widget.filterCtl,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '过滤关键字(不区分大小写)',
              border: UnderlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              DropdownButton<TextCodec>(
                value: widget.codec,
                underline: const SizedBox.shrink(),
                items: TextCodec.values
                    .map((c) => DropdownMenuItem(
                        value: c, child: Text(c.label)))
                    .toList(),
                onChanged: (v) =>
                    widget.onFormat(v ?? TextCodec.hex),
              ),
              const SizedBox(width: 8),
              _toggleChip('自动滚动', _autoScroll,
                  (v) => setState(() => _autoScroll = v)),
              const SizedBox(width: 8),
              _toggleChip('显示发送', _showSend,
                  (v) => setState(() => _showSend = v)),
              const Spacer(),
              // 暂停/清屏/清零（对标原版）
              _ctlBtn(_paused ? Icons.play_arrow : Icons.pause,
                  _paused ? '继续' : '暂停', () {
                setState(() {
                  if (!_paused) {
                    _pausedList = _visible(engine.logs.value);
                  }
                  _paused = !_paused;
                });
              }),
              _ctlBtn(Icons.clear_all, '清屏', () {
                engine.clearLogs();
                setState(() {
                  _paused = false;
                  _pausedList = [];
                });
              }),
              _ctlBtn(Icons.exposure_zero, '清零', () {
                session.resetStats();
              }),
            ],
          ),
        ),
        // 统计行
        ValueListenableBuilder<int>(
          valueListenable: session.statsBump,
          builder: (_, __, ___) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              children: [
                const Icon(Icons.arrow_downward,
                    color: Colors.green, size: 14),
                Text(' 收:${session.recvPkts}包, ${session.recvBytes}字节  ',
                    style: const TextStyle(fontSize: 11)),
                const Icon(Icons.arrow_upward,
                    color: Color(0xFFF57C00), size: 14),
                Text(
                  ' 发: 成功:${session.sentOkPkts}包, ${session.sentOkBytes}字节 '
                  '失败: ${session.sentFailPkts}包, 0字节',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _paused
              ? _buildList(_pausedList)
              : ValueListenableBuilder<List<LogEntry>>(
                  valueListenable: engine.logs,
                  builder: (_, allLogs, ___) =>
                      _buildList(_visible(allLogs)),
                ),
        ),
      ],
    );
  }

  bool _match(LogEntry e, String kw) {
    if (kw.isEmpty) return true;
    final lower = kw.toLowerCase();
    final text = HexUtil.toText(e.bytes, widget.codec).toLowerCase();
    return text.contains(lower) ||
        e.tag.toLowerCase().contains(lower) ||
        (e.message ?? '').toLowerCase().contains(lower);
  }

  List<LogEntry> _visible(List<LogEntry> allLogs) {
    final kw = widget.filterCtl.text;
    return allLogs
        .where((e) => _match(e, kw))
        .where((e) =>
            e.dir == LogDir.event ||
            (_showSend
                ? true
                : (e.dir != LogDir.sendOk && e.dir != LogDir.sendFail)))
        .toList();
  }

  // ---------- 导出 ----------
  void _exportLogs(List<LogEntry> list, _ExportMode mode) {
    final sb = StringBuffer();
    for (final e in list) {
      if (e.dir == LogDir.event) continue;
      if (mode == _ExportMode.hexTs) {
        sb.write('${e.timeStr}  ${e.dirStr} [${e.tag}] ');
        sb.writeln(HexUtil.toHex(e.bytes));
      } else if (mode == _ExportMode.hex) {
        sb.writeln(HexUtil.toHex(e.bytes));
      } else {
        sb.writeln(HexUtil.toAscii(e.bytes));
      }
    }
    Clipboard.setData(ClipboardData(text: sb.toString()));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已导出 ${list.length} 条数据到剪贴板'),
        duration: const Duration(milliseconds: 800)));
  }

  /// 导出全部到 txt 文件（落盘）
  Future<void> _exportLogsToFile(List<LogEntry> list, _ExportMode mode) async {
    try {
      final sb = StringBuffer();
      for (final e in list) {
        if (e.dir == LogDir.event) continue;
        if (mode == _ExportMode.hexTs) {
          sb.write('${e.timeStr}  ${e.dirStr} [${e.tag}] ');
          sb.writeln(HexUtil.toHex(e.bytes));
        } else if (mode == _ExportMode.hex) {
          sb.writeln(HexUtil.toHex(e.bytes));
        } else {
          sb.writeln(HexUtil.toAscii(e.bytes));
        }
      }
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = await FilePicker.platform.saveFile(
        fileName: 'ble_data_$ts.txt',
        bytes: Uint8List.fromList(utf8.encode(sb.toString())),
      );
      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已保存 $path'),
            duration: const Duration(milliseconds: 800)));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('导出失败: $e'),
          duration: const Duration(milliseconds: 800)));
    }
  }

  void _showExportSheet(LogEntry? single, List<LogEntry> all) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(single == null ? '导出全部接收/发送数据' : '导出数据',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (single != null) ...[
              ListTile(
                leading: const Icon(Icons.copy, size: 20),
                title: const Text('复制本条（16进制）'),
                onTap: () {
                  Clipboard.setData(
                      ClipboardData(text: HexUtil.toHex(single.bytes)));
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy, size: 20),
                title: const Text('复制本条（ASCII）'),
                onTap: () {
                  Clipboard.setData(
                      ClipboardData(text: HexUtil.toAscii(single.bytes)));
                  Navigator.pop(ctx);
                },
              ),
            ],
            const Divider(),
            ListTile(
              leading: const Icon(Icons.content_copy, size: 20),
              title: const Text('复制全部（16进制）'),
              onTap: () {
                _exportLogs(all, _ExportMode.hex);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_copy, size: 20),
              title: const Text('复制全部（16进制，带时间戳）'),
              onTap: () {
                _exportLogs(all, _ExportMode.hexTs);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_copy, size: 20),
              title: const Text('复制全部（ASCII）'),
              onTap: () {
                _exportLogs(all, _ExportMode.ascii);
                Navigator.pop(ctx);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.file_download, size: 20),
              title: const Text('导出到文件（16进制）'),
              onTap: () {
                _exportLogsToFile(all, _ExportMode.hex);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_download, size: 20),
              title: const Text('导出到文件（16进制，带时间戳）'),
              onTap: () {
                _exportLogsToFile(all, _ExportMode.hexTs);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_download, size: 20),
              title: const Text('导出到文件（ASCII）'),
              onTap: () {
                _exportLogsToFile(all, _ExportMode.ascii);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(List<LogEntry> list) {
    if (_autoScroll && !_paused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (widget.logScroll.hasClients) {
          widget.logScroll
              .jumpTo(widget.logScroll.position.maxScrollExtent);
        }
      });
    }
    if (list.isEmpty) {
      return const Center(
          child: Text('暂无日志', style: TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      controller: widget.logScroll,
      itemCount: list.length,
      itemBuilder: (_, i) => _LogLine(
        entry: list[i],
        codec: widget.codec,
        translate: widget.translate &&
            widget.codec == TextCodec.hex &&
            widget.translateSnapshot != null &&
            !list[i].time.isAfter(widget.translateSnapshot!),
        onLongPress: () => _showExportSheet(list[i], list),
      ),
    );
  }

  Widget _toggleChip(String label, bool on, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!on),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFF57C00) : Colors.grey.shade400,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12, color: on ? Colors.white : Colors.black54)),
      ),
    );
  }

  Widget _ctlBtn(IconData icon, String tip, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: Colors.black54),
            Text(tip, style: const TextStyle(fontSize: 9)),
          ],
        ),
      ),
    );
  }
}

enum _ExportMode { hex, hexTs, ascii }

/// 日志行（行结构可配置：时间> [主题] 动作: "数据"）
/// translate=true 时把 hex 翻译成可打印文本（带背景色），翻不出的保持 hex
class _LogLine extends StatelessWidget {
  final LogEntry entry;
  final TextCodec codec;
  final bool translate;
  final VoidCallback onLongPress;

  const _LogLine({
    required this.entry,
    required this.codec,
    this.translate = false,
    required this.onLongPress,
  });

  /// 按用户配置拼行（导出 txt 用）
  static String format(LogEntry e, TextCodec codec,
      {required bool showTime, required bool showTag,
      required bool showDir, required bool showQuote}) {
    final sb = StringBuffer();
    if (showTime) sb.write('${e.timeStr}> ');
    if (showTag && e.tag.isNotEmpty) sb.write('[${e.tag}] ');
    if (showDir) sb.write('${e.dirStr} ');
    final data = HexUtil.toText(e.bytes, codec);
    sb.write(showQuote ? '"$data"' : data);
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final engine = BleEngine.instance;
    final Color dirColor;
    switch (e.dir) {
      case LogDir.notify:
      case LogDir.indicate:
      case LogDir.read:
        dirColor = const Color(0xFF2E7D32); // 柔和绿
        break;
      case LogDir.sendOk:
        dirColor = const Color(0xFFF57C00); // 橙
        break;
      case LogDir.sendFail:
        dirColor = Colors.red;
        break;
      case LogDir.event:
        dirColor = Colors.black54;
    }
    final isEvent = e.dir == LogDir.event;

    final List<InlineSpan> tail;
    if (isEvent) {
      tail = [TextSpan(text: e.message ?? '')];
    } else if (translate) {
      // 翻译模式：可打印字节 → 文字（带背景色），不可打印 → hex
      tail = _buildTranslatedSpans(e, dirColor);
    } else {
      final data = HexUtil.toText(e.bytes, codec);
      final text = engine.logShowQuote ? '"$data"' : data;
      tail = [
        if (engine.logShowDir) TextSpan(text: '${e.dirStr} ', style: TextStyle(color: dirColor)),
        TextSpan(
          text: text,
          style: TextStyle(color: dirColor, fontFamily: 'monospace'),
        ),
      ];
    }

    return InkWell(
      onLongPress: isEvent ? null : onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Text.rich(
          TextSpan(
            style: const TextStyle(
                fontSize: 13, height: 1.5, color: Colors.black87),
            children: [
              if (engine.logShowTime)
                TextSpan(
                  text: '${e.timeStr}> ',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: Colors.grey.shade500,
                      fontFamily: 'monospace'),
                ),
              if (!isEvent && engine.logShowTag && e.tag.isNotEmpty)
                TextSpan(
                    text: '[${e.tag}] ',
                    style: const TextStyle(
                        color: Color(0xFF1565C0), fontFamily: 'monospace')),
              ...tail,
            ],
          ),
        ),
      ),
    );
  }

  /// 翻译模式数据段：连续可打印字节拼成文字加背景色，其余保持 hex
  List<InlineSpan> _buildTranslatedSpans(LogEntry e, Color dirColor) {
    final spans = <InlineSpan>[];
    final sb = StringBuffer();
    void flushText() {
      if (sb.isEmpty) return;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: const Color(0xFFFFE0B2), // 淡橙背景（翻译出的文字）
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(sb.toString(),
              style: const TextStyle(
                  fontSize: 13,
                  color: Colors.black87,
                  fontFamily: 'monospace')),
        ),
      ));
      sb.clear();
    }

    if (BleEngine.instance.logShowDir) {
      spans.add(TextSpan(
          text: '${e.dirStr} ', style: TextStyle(color: dirColor)));
    }
    for (final b in e.bytes) {
      if (b >= 0x20 && b <= 0x7E) {
        sb.writeCharCode(b);
      } else {
        flushText();
        spans.add(TextSpan(
          text:
              '${b.toRadixString(16).padLeft(2, '0').toUpperCase()} ',
          style: TextStyle(color: dirColor, fontFamily: 'monospace'),
        ));
      }
    }
    flushText();
    return spans;
  }
}
