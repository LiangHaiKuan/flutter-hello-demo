import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../core/ble_util.dart';
import '../models/models.dart';
import '../services/ble_engine.dart';

/// 外围模式：手机当 BLE 从机（广播 + GATT 服务器）
///
/// 对标旧软件「初始化」+「外围模式」两个界面，并新增：
/// - 回复规则（收到什么回复什么）：收到匹配数据后自动回复指定内容；
/// - 规则支持导入/导出（暂不走云端）。

// ============================================================
// 外围模式运行时（页面之间共享，全局单例）
// ============================================================
class PeripheralLogEntry {
  final DateTime time;
  final List<int> bytes;
  final bool isSend; // true=发送的通知, false=收到中央写入
  final String? message;

  PeripheralLogEntry(
      {required this.time, this.bytes = const [], this.isSend = false, this.message});

  String get timeStr =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}.'
      '${time.millisecond.toString().padLeft(3, '0')}';
}

class PeripheralManager {
  PeripheralManager._();
  static final PeripheralManager instance = PeripheralManager._();

  bool advertising = false;
  final ValueNotifier<int> bump = ValueNotifier(0); // 日志/状态变化通知
  final List<PeripheralLogEntry> logs = [];
  final Set<String> _subscribers = {}; // 已订阅的中央设备
  Timer? _loopTimer;

  void log(String msg) {
    logs.add(PeripheralLogEntry(time: DateTime.now(), message: msg));
    if (logs.length > 2000) logs.removeRange(0, logs.length - 2000);
    bump.value++;
  }

  void _logData(List<int> bytes, bool isSend) {
    logs.add(PeripheralLogEntry(
        time: DateTime.now(), bytes: bytes, isSend: isSend));
    bump.value++;
  }

  /// 配置并开始广播
  Future<void> start() async {
    final e = BleEngine.instance;
    stopLoop();
    try {
      await BlePeripheral.stopAdvertising();
      await BlePeripheral.clearServices();
    } catch (_) {}

    BlePeripheral.setAdvertisingStatusUpdateCallback(
        (bool adv, String? error) {
      advertising = adv;
      log(adv ? '开始广播' : '广播已停止${error == null ? '' : '（错误: $error）'}');
      bump.value++;
    });
    BlePeripheral.setConnectionStateChangeCallback((deviceId, connected) {
      log(connected ? '中央设备已连接: $deviceId' : '中央设备已断开: $deviceId');
      if (!connected) _subscribers.remove(deviceId);
    });
    BlePeripheral.setCharacteristicSubscriptionChangeCallback((deviceId,
        characteristicId, isSubscribed, name) {
      if (isSubscribed) {
        _subscribers.add(deviceId);
        log('中央设备订阅了特征 $characteristicId');
      } else {
        _subscribers.remove(deviceId);
        log('中央设备取消订阅 $characteristicId');
      }
    });
    // 中央读取特征值 → 返回当前"特征数据"
    BlePeripheral.setReadRequestCallback(
        (deviceId, characteristicId, offset, value) {
      final bytes =
          HexUtil.parse(e.advCharData, TextCodec.hex) ?? Uint8List(0);
      log('中央读取特征 $characteristicId → 返回 ${HexUtil.toHex(bytes)}');
      return ReadRequestResult(value: bytes);
    });
    // 中央写入 → 日志 + 回复规则 / 被写入响应
    BlePeripheral.setWriteRequestCallback(
        (deviceId, characteristicId, offset, value) {
      _logData(value, false);
      _onWritten(value);
      return null; // 自动 ACK
    });

    try {
      await BlePeripheral.initialize();
      // GATT 服务（特征设置里的 服务UUID + 特征UUID）
      await BlePeripheral.addService(BleService(
        uuid: e.advCharServiceUuid,
        primary: true,
        characteristics: [
          BleCharacteristic(
            uuid: e.advCharUuid,
            properties: [
              CharacteristicProperties.read.index,
              CharacteristicProperties.write.index,
              CharacteristicProperties.writeWithoutResponse.index,
              CharacteristicProperties.notify.index,
            ],
            value: HexUtil.parse(e.advCharData, TextCodec.hex),
            permissions: [
              AttributePermissions.readable.index,
              AttributePermissions.writeable.index,
            ],
          ),
        ],
      ));
      // 开始广播（广播设置里的 服务UUID）
      await BlePeripheral.startAdvertising(
        services: [e.advServiceUuid],
        localName: e.advLocalName,
      );
    } catch (err) {
      log('启动失败: $err');
      advertising = false;
      bump.value++;
      rethrow;
    }

  // 循环响应模式：定时发送通知数据
  if (e.advResponseMode == 1) {
    startLoop();
  }
}

/// 启动循环发送定时器（通知响应模式=循环）
void startLoop() {
  final e = BleEngine.instance;
  stopLoop();
  _loopTimer = Timer.periodic(Duration(milliseconds: e.advLoopDelayMs), (_) {
    _sendNotifyData();
  });
}

  /// 收到中央写入后的处理：先匹配回复规则，无匹配且为"被写入"模式则回通知数据
  void _onWritten(List<int> bytes) {
    final e = BleEngine.instance;
    final recvHex = HexUtil.toHex(bytes).replaceAll(' ', '').toUpperCase();
    for (final r in e.replyRules) {
      if (!r.enabled) continue;
      bool hit;
      if (r.match.isEmpty) {
        hit = true; // 空匹配 = 任意数据都回复
      } else if (r.hexMode) {
        hit = recvHex == _normHex(r.match);
      } else {
        hit = HexUtil.toAscii(bytes) == r.match;
      }
      if (hit) {
        final reply = HexUtil.parse(r.reply, r.hexMode ? TextCodec.hex : TextCodec.ascii);
        if (reply != null) {
          log('命中回复规则 [${r.match.isEmpty ? '任意' : r.match} → ${r.reply}]');
          _notify(reply);
        }
        return;
      }
    }
    if (e.advResponseMode == 0) {
      _sendNotifyData();
    }
  }

  String _normHex(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'[\s,:]+'), '').toUpperCase();

  Future<void> _sendNotifyData() async {
    final e = BleEngine.instance;
    final bytes = HexUtil.parse(e.advNotifyData, TextCodec.hex);
    if (bytes == null || bytes.isEmpty) return;
    _notify(bytes);
  }

  Future<void> _notify(List<int> bytes) async {
    final e = BleEngine.instance;
    try {
      await BlePeripheral.updateCharacteristic(
        characteristicId: e.advCharUuid,
        value: Uint8List.fromList(bytes),
      );
      _logData(bytes, true);
    } catch (err) {
      log('发送通知失败（可能没有设备订阅）: $err');
    }
  }

  void stopLoop() {
    _loopTimer?.cancel();
    _loopTimer = null;
  }

  Future<void> stop() async {
    stopLoop();
    try {
      await BlePeripheral.stopAdvertising();
      await BlePeripheral.clearServices();
    } catch (_) {}
    advertising = false;
    bump.value++;
  }

  void clearLogs() {
    logs.clear();
    bump.value++;
  }
}

// ============================================================
// 初始化配置页（对标旧软件「初始化」）
// ============================================================
class PeripheralConfigPage extends StatefulWidget {
  const PeripheralConfigPage({super.key});

  @override
  State<PeripheralConfigPage> createState() => _PeripheralConfigPageState();
}

class _PeripheralConfigPageState extends State<PeripheralConfigPage> {
  final BleEngine _engine = BleEngine.instance;

  late final TextEditingController _nameCtl;
  late final TextEditingController _advSvcCtl;
  late final TextEditingController _charSvcCtl;
  late final TextEditingController _charCtl;
  late final TextEditingController _charDataCtl;
  late final TextEditingController _notifyDataCtl;
  late final TextEditingController _delayCtl;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: _engine.advLocalName);
    _advSvcCtl = TextEditingController(text: _engine.advServiceUuid);
    _charSvcCtl = TextEditingController(text: _engine.advCharServiceUuid);
    _charCtl = TextEditingController(text: _engine.advCharUuid);
    _charDataCtl = TextEditingController(text: _engine.advCharData);
    _notifyDataCtl = TextEditingController(text: _engine.advNotifyData);
    _delayCtl = TextEditingController(text: '${_engine.advLoopDelayMs}');
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _advSvcCtl.dispose();
    _charSvcCtl.dispose();
    _charCtl.dispose();
    _charDataCtl.dispose();
    _notifyDataCtl.dispose();
    _delayCtl.dispose();
    super.dispose();
  }

  Future<void> _saveConfig() async {
    _engine.advLocalName = _nameCtl.text.trim();
    _engine.advServiceUuid = _advSvcCtl.text.trim();
    _engine.advCharServiceUuid = _charSvcCtl.text.trim();
    _engine.advCharUuid = _charCtl.text.trim();
    _engine.advCharData = _charDataCtl.text.trim();
    _engine.advNotifyData = _notifyDataCtl.text.trim();
    _engine.advLoopDelayMs = int.tryParse(_delayCtl.text) ?? 500;
    await _engine.saveAdvConfig();
  }

  Future<void> _startAdvertise() async {
    // 权限
    await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
    ].request();
    await _saveConfig();
    try {
      await PeripheralManager.instance.start();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('启动失败: $e'),
            duration: const Duration(milliseconds: 1500)));
      }
      return;
    }
    if (mounted) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const PeripheralLogPage(),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        title: const Text('初始化'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('广播设置',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold, color: Colors.grey)),
          _field('广播名称', _nameCtl, hint: 'BLE调试助手'),
          _field('服务UUID', _advSvcCtl, hint: '0000ff11-0000-1000-8000-00805f9b34fb'),
          const SizedBox(height: 16),
          const Text('特征设置',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold, color: Colors.grey)),
          _field('服务UUID', _charSvcCtl, hint: '0000ff00-0000-1000-8000-00805f9b34fb'),
          _field('特征UUID', _charCtl, hint: '0000ff01-0000-1000-8000-00805f9b34fb'),
          _field('特征数据（中央读取时返回，hex）', _charDataCtl, hint: '010203040506'),
          _field('通知数据（响应模式发送，hex）', _notifyDataCtl, hint: '060504030201'),
          const SizedBox(height: 8),
          const Text('通知响应模式',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold, color: Colors.grey)),
          Row(
            children: [
              Radio<int>(
                value: 0,
                groupValue: _engine.advResponseMode,
                activeColor: const Color(0xFFF57C00),
                onChanged: (v) => setState(() => _engine.advResponseMode = v ?? 0),
              ),
              const Text('被写入'),
              const SizedBox(width: 16),
              Radio<int>(
                value: 1,
                groupValue: _engine.advResponseMode,
                activeColor: const Color(0xFFF57C00),
                onChanged: (v) => setState(() => _engine.advResponseMode = v ?? 1),
              ),
              const Text('循环'),
              const Text('  延时(ms): '),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: _delayCtl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(isDense: true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.rule, color: Color(0xFFF57C00)),
            title: Text('回复规则（收到什么回复什么，共 ${_engine.replyRules.length} 条）'),
            subtitle: const Text('例：收到 A1 就自动回复 B2。可导入/导出/编辑'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editReplyRules,
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 46,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF57C00),
                foregroundColor: Colors.white,
              ),
              onPressed: _startAdvertise,
              child: const Text('开始广播', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController ctl, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: ctl,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          hintText: hint,
          border: const UnderlineInputBorder(),
        ),
      ),
    );
  }

  // ---------- 回复规则管理 ----------
  Future<void> _editReplyRules() async {
    await showDialog<bool>(
      context: context,
      builder: (ctx) => const _ReplyRuleDialog(),
    );
    setState(() {});
  }
}

// ============================================================
// 回复规则弹窗：列表 + 增删改 + 导入/导出
// ============================================================
class _ReplyRuleDialog extends StatelessWidget {
  const _ReplyRuleDialog();

  Future<void> _editRule(BuildContext ctx, ReplyRule? rule) async {
    final matchCtl = TextEditingController(text: rule?.match ?? '');
    final replyCtl = TextEditingController(text: rule?.reply ?? '');
    bool hexMode = rule?.hexMode ?? true;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text(rule == null ? '添加规则' : '修改规则'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: matchCtl,
                decoration: InputDecoration(
                  labelText: hexMode ? '收到内容（hex，留空=任意）' : '收到内容（文本，留空=任意）',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: replyCtl,
                decoration: InputDecoration(
                  labelText: hexMode ? '回复内容（hex）' : '回复内容（文本）',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  ChoiceChip(
                      label: const Text('hex'),
                      selected: hexMode,
                      onSelected: (_) => setD(() => hexMode = true)),
                  const SizedBox(width: 8),
                  ChoiceChip(
                      label: const Text('ascii'),
                      selected: !hexMode,
                      onSelected: (_) => setD(() => hexMode = false)),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消')),
            ElevatedButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final e = BleEngine.instance;
    if (rule == null) {
      e.replyRules.add(ReplyRule(
          match: matchCtl.text.trim(),
          reply: replyCtl.text.trim(),
          hexMode: hexMode));
    } else {
      rule.match = matchCtl.text.trim();
      rule.reply = replyCtl.text.trim();
      rule.hexMode = hexMode;
    }
    await e.saveAdvConfig();
  }

  void _importRules(BuildContext ctx) async {
    final e = BleEngine.instance;
    try {
      final res = await FilePicker.platform.pickFiles(
          type: FileType.custom, allowedExtensions: ['txt']);
      if (res == null || res.files.isEmpty) return;
      final path = res.files.single.path;
      if (path == null) return;
      final raw = await File(path).readAsString();
      final parsed = _parseReplyRules(raw);
      if (parsed.isEmpty) {
        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
            content: Text('没有解析到有效规则（格式: 序号→收到,hex,回复）')));
        return;
      }
      e.replyRules.addAll(parsed);
      await e.saveAdvConfig();
      ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('导入 ${parsed.length} 条规则')));
    } catch (err) {
      ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('导入失败: $err')));
    }
  }

  void _exportRules(BuildContext ctx) async {
    final e = BleEngine.instance;
    final text = e.replyRules
        .asMap()
        .entries
        .map((entry) =>
            '${entry.key + 1}\u2192${entry.value.match},${entry.value.hexMode ? 'hex' : 'ascii'},${entry.value.reply}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text(
            e.replyRules.isEmpty ? '暂无规则' : '已导出 ${e.replyRules.length} 条规则到剪贴板')));
  }

  @override
  Widget build(BuildContext context) {
    final e = BleEngine.instance;
    return StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: const Text('回复规则（收到什么回复什么）'),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: e.replyRules.isEmpty
              ? const Center(
                  child: Text('还没有规则。\n添加一条：收到 A1 → 回复 B2',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: e.replyRules.length,
                  itemBuilder: (_, i) {
                    final r = e.replyRules[i];
                    return ListTile(
                      dense: true,
                      leading: Checkbox(
                        value: r.enabled,
                        activeColor: const Color(0xFFF57C00),
                        onChanged: (v) {
                          setD(() => r.enabled = v ?? true);
                          e.saveAdvConfig();
                        },
                      ),
                      title: Text(
                        '${r.match.isEmpty ? '任意' : r.match}  →  ${r.reply}',
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      subtitle: Text(r.hexMode ? 'hex' : 'ascii',
                          style: const TextStyle(fontSize: 11)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                              icon: const Icon(Icons.edit, size: 18),
                              onPressed: () async {
                                await _editRule(ctx, r);
                                setD(() {});
                              }),
                          IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 18, color: Colors.redAccent),
                              onPressed: () async {
                                setD(() => e.replyRules.removeAt(i));
                                await e.saveAdvConfig();
                              }),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => _importRules(ctx),
              child: const Text('导入')),
          TextButton(
              onPressed: () => _exportRules(ctx),
              child: const Text('导出')),
          TextButton(
              onPressed: () async {
                await _editRule(ctx, null);
                setD(() {});
              },
              child: const Text('添加')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('完成')),
        ],
      ),
    );
  }
}

/// 回复规则文本解析：`序号→收到,格式,回复`，// 注释与无效行跳过
List<ReplyRule> _parseReplyRules(String text) {
  final out = <ReplyRule>[];
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final l = line.trim();
    if (l.isEmpty || l.startsWith('//')) continue;
    final arrow = l.indexOf('\u2192');
    if (arrow < 0) continue;
    final body = l.substring(arrow + 1);
    final segs = body.split(',');
    if (segs.length < 3) continue;
    final match = segs[0].trim();
    final fmt = segs[1].trim().toLowerCase();
    final reply = segs.sublist(2).join(',').trim();
    if (reply.isEmpty) continue;
    final isAscii = fmt == 'us-ascii' || fmt == 'ascii';
    final isHex = fmt == 'hex' || fmt == '0x';
    if (!isAscii && !isHex) continue;
    out.add(ReplyRule(
        match: match == '(任意)' ? '' : match,
        reply: reply,
        hexMode: !isAscii));
  }
  return out;
}

// ============================================================
// 外围模式日志页（对标旧软件「外围模式」）
// ============================================================
class PeripheralLogPage extends StatefulWidget {
  const PeripheralLogPage({super.key});

  @override
  State<PeripheralLogPage> createState() => _PeripheralLogPageState();
}

class _PeripheralLogPageState extends State<PeripheralLogPage> {
  final BleEngine _engine = BleEngine.instance;
  final PeripheralManager _pm = PeripheralManager.instance;
  final ScrollController _scroll = ScrollController();
  bool _hexMode = true;
  bool _autoScroll = true;
  bool _simplified = false; // 简化：不显示时间
  bool _paused = false;
  List<PeripheralLogEntry> _pausedList = [];

  @override
  void initState() {
    super.initState();
    _pm.bump.addListener(_onBump);
  }

  void _onBump() {
    if (!mounted) return;
    setState(() {});
    if (_autoScroll && !_paused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _pm.bump.removeListener(_onBump);
    _scroll.dispose();
    // 离开页面停止广播
    _pm.stop();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(milliseconds: 800)));
  }

  // ---------- 日志导出 ----------
  String _buildLogText() {
    final sb = StringBuffer();
    for (final l in _pm.logs) {
      if (l.message != null) {
        sb.writeln('${l.timeStr}> ${l.message}');
      } else {
        final dir = l.isSend ? '通知发送:' : '被写入:';
        sb.writeln(
            '${_simplified ? '' : '${l.timeStr}> '}[$dir] "${HexUtil.toHex(l.bytes)}"');
      }
    }
    return sb.toString();
  }

  Future<void> _exportLogs() async {
    try {
      final text = _buildLogText();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = await FilePicker.platform.saveFile(
        fileName: 'peripheral_log_$ts.txt',
        bytes: Uint8List.fromList(utf8.encode(text)),
      );
      if (path != null) _toast('日志已保存到 $path');
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
    await Share.share(text, subject: '外围模式日志');
  }

  // ---------- 三点菜单 ----------
  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.rule, color: Color(0xFFF57C00)),
              title: Text('回复规则（${_engine.replyRules.length} 条）'),
              onTap: () {
                Navigator.pop(ctx);
                showDialog(
                    context: context,
                    builder: (_) => const _ReplyRuleDialog()).then((_) {
                  setState(() {});
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_download, color: Color(0xFFF57C00)),
              title: const Text('导出日志'),
              onTap: () {
                Navigator.pop(ctx);
                _exportLogs();
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
              leading: const Icon(Icons.stop_circle, color: Colors.redAccent),
              title: const Text('停止广播并退出'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 响应模式切换 ----------
  Future<void> _setResponseMode(int mode) async {
    _engine.advResponseMode = mode;
    _pm.stopLoop();
    if (mode == 1) {
      _pm.startLoop(); // 只重启循环定时器，不动广播
    }
    await _engine.saveAdvConfig();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        title: const Text('外围模式'),
        actions: [
          TextButton(
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PeripheralConfigPage(),
                ));
              },
              child: const Text('设置', style: TextStyle(color: Colors.white))),
          IconButton(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              onPressed: _showMoreMenu),
        ],
      ),
      body: Column(
        children: [
          // ---------- 控制区 ----------
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                const Text('日志打印',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(width: 6),
                _chip('HEX', _hexMode, () => setState(() => _hexMode = true)),
                const SizedBox(width: 4),
                _chip('ASCII', !_hexMode, () => setState(() => _hexMode = false)),
                const Spacer(),
                _check('简化', _simplified, (v) => setState(() => _simplified = v)),
                _check('自动滚动', _autoScroll, (v) => setState(() => _autoScroll = v)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                const Text('通知响应模式:',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(width: 6),
                _chip('被写入', _engine.advResponseMode == 0,
                    () => _setResponseMode(0)),
                const SizedBox(width: 4),
                _chip('循环', _engine.advResponseMode == 1,
                    () => _setResponseMode(1)),
                if (_engine.advResponseMode == 1)
                  Text(' ${_engine.advLoopDelayMs}ms',
                      style: const TextStyle(fontSize: 12)),
                const Spacer(),
                _btn('暂停', _paused, () {
                  setState(() {
                    if (!_paused) {
                      _pausedList = List.from(_pm.logs);
                    }
                    _paused = !_paused;
                  });
                }),
                _btn('清屏', false, () {
                  _pm.clearLogs();
                  setState(() {
                    _paused = false;
                    _pausedList = [];
                  });
                }),
              ],
            ),
          ),
          const Divider(height: 1),
          // ---------- 广播状态圆环 ----------
          ValueListenableBuilder<int>(
            valueListenable: _pm.bump,
            builder: (_, __, ___) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: [
                  _AdvertiseCircle(advertising: _pm.advertising),
                  const SizedBox(height: 8),
                  Text(
                    _pm.advertising
                        ? '${_engine.advLocalName} 广播中 · 订阅设备 ${_pm._subscribers.length}'
                        : '广播已停止',
                    style: TextStyle(
                        fontSize: 13,
                        color: _pm.advertising
                            ? Colors.black87
                            : Colors.grey)),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          // ---------- 日志列表 ----------
          Expanded(
            child: _paused
                ? _buildLogList(_pausedList)
                : _buildLogList(_pm.logs),
          ),
        ],
      ),
    );
  }

  Widget _buildLogList(List<PeripheralLogEntry> list) {
    if (list.isEmpty) {
      return const Center(
          child: Text('暂无日志（等待中央设备连接写入）',
              style: TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: list.length,
      itemBuilder: (_, i) {
        final l = list[i];
        if (l.message != null) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Text('${_simplified ? '' : '${l.timeStr}> '}${l.message}',
                style: const TextStyle(
                    fontSize: 12, color: Colors.black54, height: 1.4)),
          );
        }
        final color = l.isSend ? const Color(0xFFF57C00) : const Color(0xFF2E7D32);
        final data = _hexMode
            ? HexUtil.toHex(l.bytes)
            : HexUtil.toAscii(l.bytes);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Text.rich(
            TextSpan(
              style: const TextStyle(fontSize: 13, height: 1.5),
              children: [
                if (!_simplified)
                  TextSpan(
                    text: '${l.timeStr}> ',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.grey.shade500,
                        fontFamily: 'monospace'),
                  ),
                TextSpan(text: '[${l.isSend ? '通知发送:' : '被写入:'}] ',
                    style: TextStyle(color: color)),
                TextSpan(
                    text: '"$data"',
                    style: TextStyle(
                        color: color, fontFamily: 'monospace')),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFF57C00) : Colors.grey.shade300,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12, color: on ? Colors.white : Colors.black54)),
      ),
    );
  }

  Widget _check(String label, bool v, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 22,
          height: 22,
          child: Checkbox(
            value: v,
            activeColor: const Color(0xFFF57C00),
            onChanged: (x) => onChanged(x ?? false),
          ),
        ),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Widget _btn(String label, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor:
              active ? const Color(0xFFF57C00) : Colors.grey.shade300,
          foregroundColor: active ? Colors.white : Colors.black54,
          minimumSize: const Size(52, 32),
          padding: EdgeInsets.zero,
        ),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(fontSize: 13)),
      ),
    );
  }
}

/// 广播状态圆环动画
class _AdvertiseCircle extends StatefulWidget {
  final bool advertising;
  const _AdvertiseCircle({required this.advertising});

  @override
  State<_AdvertiseCircle> createState() => _AdvertiseCircleState();
}

class _AdvertiseCircleState extends State<_AdvertiseCircle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.advertising) ...[
            _ring(180, 0.15),
            _ring(130, 0.25),
          ],
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: const Color(0xFF2196F3),
              borderRadius: BorderRadius.circular(42),
            ),
            child: const Icon(Icons.bluetooth_audio,
                color: Colors.white, size: 40),
          ),
        ],
      ),
    );
  }

  Widget _ring(double size, double opacity) {
    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 1.0).animate(_ctl),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFF57C00).withAlpha(38),
          borderRadius: BorderRadius.circular(size / 2),
        ),
      ),
    );
  }
}
