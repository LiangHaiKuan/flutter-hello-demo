import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/ble_util.dart';
import '../models/models.dart';
import '../services/ble_engine.dart';
import 'fast_cmd_page.dart';

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
  bool _autoScroll = true;
  bool _showSend = true;
  bool _hexMode = true;
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
    _sendCtl.text = 'aa00bb11cc22';
  }

  @override
  void dispose() {
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
    final bytes = HexUtil.parse(text, _hexMode);
    if (bytes == null) {
      _toast('数据格式错误');
      return;
    }
    if (session.targetChar.value == null) {
      _toast('请先在蓝牙服务页选择一个可写特征值');
      return;
    }
    final withoutResponse =
        _writeType == _WriteType.noResponse;
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

  // ---------- 特征值操作 ----------
  Future<void> _showWriteDialog(BluetoothCharacteristic c) async {
    final ctl = TextEditingController();
    bool hex = true;
    bool noResp = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('写入 ${UuidNames.charName(c.uuid.str)}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: hex ? 'aa00bb11cc22（支持空格）' : '输入 ascii 文本',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ChoiceChip(
                    label: const Text('hex'),
                    selected: hex,
                    onSelected: (_) => setD(() => hex = true),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('ascii'),
                    selected: !hex,
                    onSelected: (_) => setD(() => hex = false),
                  ),
                  const Spacer(),
                  Checkbox(
                    value: noResp,
                    onChanged: (v) => setD(() => noResp = v ?? false),
                  ),
                  const Text('无响应写'),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('写入')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final bytes = HexUtil.parse(ctl.text, hex);
    if (bytes == null) {
      _toast('数据格式错误');
      return;
    }
    session.targetChar.value = c;
    await session.send(bytes, noResp);
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
                          final bytes =
                              HexUtil.parse(c.data, c.hexMode);
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

  // ---------- 构建 ----------
  @override
  Widget build(BuildContext context) {
    if (_engine.sessionOf(widget.mac) == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('BLE调试助手')),
        body: const Center(child: Text('设备未连接或连接已断开')),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => Navigator.of(context).pop()),
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
            TextButton(
                onPressed: () => session.disconnect(),
                child: const Text('断开', style: TextStyle(color: Colors.white))),
          ],
          bottom: const TabBar(
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [Tab(text: '蓝牙服务'), Tab(text: '实时日志')],
          ),
        ),
        body: TabBarView(
          children: [
            _ServicesTab(session: session, onWrite: _showWriteDialog,
                onRead: session.readChar, onNotifyToggle: _toggleNotify,
                onPickTarget: _pickTargetChar),
            _LogTab(
              session: session,
              autoScroll: _autoScroll,
              showSend: _showSend,
              hexMode: _hexMode,
              filterCtl: _filterCtl,
              logScroll: _logScroll,
              onToggleAuto: (v) => setState(() => _autoScroll = v),
              onToggleShowSend: (v) => setState(() => _showSend = v),
              onFormat: (v) => setState(() => _hexMode = v),
            ),
          ],
        ),
        bottomNavigationBar: _buildSendBar(),
      ),
    );
  }

  Future<void> _toggleNotify(BluetoothCharacteristic c, bool v) async {
    await session.setNotify(c, v);
  }

  Widget _buildSendBar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _sendCtl,
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
                onPressed: _sendOnce,
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            children: [
              Row(
                children: [
                  _iconBtn(Icons.history, '发送历史', _showHistory),
                  const SizedBox(width: 12),
                  _iconBtn(Icons.bolt, '自定义按键', _showFastCmdSheet),
                  const SizedBox(width: 12),
                  DropdownButton<bool>(
                    value: _hexMode,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: true, child: Text('hex')),
                      DropdownMenuItem(value: false, child: Text('ascii')),
                    ],
                    onChanged: (v) => setState(() => _hexMode = v ?? true),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _pickTargetChar,
                    child: ValueListenableBuilder<BluetoothCharacteristic?>(
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
              Row(
                children: [
                  _typeChip('Default', _WriteType.defaultWrite),
                  _typeChip('No Response', _WriteType.noResponse),
                  _typeChip('Signed', _WriteType.signed),
                  const Spacer(),
                  SizedBox(
                    width: 60,
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('循环', style: TextStyle(fontSize: 12)),
                      value: _loopSend,
                      activeColor: const Color(0xFFF57C00),
                      onChanged: _toggleLoop,
                    ),
                  ),
                  const Text('延时(ms):', style: TextStyle(fontSize: 12)),
                  SizedBox(
                    width: 50,
                    child: TextField(
                      controller: _delayCtl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: const TextStyle(fontSize: 12),
                      decoration:
                          const InputDecoration(isDense: true, border: UnderlineInputBorder()),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
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

// ---------------- 蓝牙服务 Tab ----------------
class _ServicesTab extends StatelessWidget {
  final DeviceSession session;
  final Future<void> Function(BluetoothCharacteristic) onWrite;
  final Future<void> Function(BluetoothCharacteristic) onRead;
  final Future<void> Function(BluetoothCharacteristic, bool) onNotifyToggle;
  final VoidCallback onPickTarget;

  const _ServicesTab({
    required this.session,
    required this.onWrite,
    required this.onRead,
    required this.onNotifyToggle,
    required this.onPickTarget,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
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
        return ListView.builder(
          itemCount: session.services.length,
          itemBuilder: (_, i) {
            final svc = session.services[i];
            final uuidStr = svc.uuid.str;
            return Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: true,
                tilePadding:
                    const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding:
                    const EdgeInsets.only(left: 16, bottom: 8),
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
                      onWrite: () => onWrite(c),
                      onRead: () => onRead(c),
                      onNotifyToggle: (v) => onNotifyToggle(c, v),
                      isTarget:
                          session.targetChar.value?.uuid.str == c.uuid.str,
                      onPickTarget: onPickTarget,
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _CharTile extends StatelessWidget {
  final DeviceSession session;
  final BluetoothCharacteristic char;
  final VoidCallback onWrite;
  final VoidCallback onRead;
  final VoidCallback onPickTarget;
  final Future<void> Function(bool) onNotifyToggle;
  final bool isTarget;

  const _CharTile({
    required this.session,
    required this.char,
    required this.onWrite,
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
              icon: const Icon(Icons.upload,
                  color: Color(0xFFF57C00), size: 20),
              tooltip: '写入（长按设为发送目标）',
              onPressed: onWrite,
              onLongPress: onPickTarget,
            ),
          if (readable)
            IconButton(
              icon: const Icon(Icons.download,
                  color: Color(0xFF4CAF50), size: 20),
              tooltip: '读取',
              onPressed: onRead,
            ),
          if (notifiable)
            Builder(builder: (_) {
              final on = s.notifyState[char.uuid.str.toLowerCase()] ?? false;
              return IconButton(
                icon: Icon(
                  on ? Icons.notifications_active : Icons.notifications_none,
                  color: on ? const Color(0xFFF57C00) : Colors.grey,
                  size: 20,
                ),
                tooltip: on ? '关闭通知' : '开启通知',
                onPressed: () => onNotifyToggle(!on),
              );
            }),
        ],
      ),
    );
  }
}

// ---------------- 实时日志 Tab ----------------
class _LogTab extends StatelessWidget {
  final DeviceSession session;
  final bool autoScroll;
  final bool showSend;
  final bool hexMode;
  final TextEditingController filterCtl;
  final ScrollController logScroll;
  final ValueChanged<bool> onToggleAuto;
  final ValueChanged<bool> onToggleShowSend;
  final ValueChanged<bool> onFormat;

  const _LogTab({
    required this.session,
    required this.autoScroll,
    required this.showSend,
    required this.hexMode,
    required this.filterCtl,
    required this.logScroll,
    required this.onToggleAuto,
    required this.onToggleShowSend,
    required this.onFormat,
  });

  bool _match(LogEntry e, String kw) {
    if (kw.isEmpty) return true;
    final lower = kw.toLowerCase();
    final text = hexMode
        ? HexUtil.toHex(e.bytes).toLowerCase()
        : HexUtil.toAscii(e.bytes).toLowerCase();
    return text.contains(lower) ||
        e.tag.toLowerCase().contains(lower) ||
        (e.message ?? '').toLowerCase().contains(lower);
  }

  @override
  Widget build(BuildContext context) {
    final engine = BleEngine.instance;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            controller: filterCtl,
            onChanged: (_) => engine.cmdsBump.value++, // 触发列表刷新
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
              DropdownButton<bool>(
                value: hexMode,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: true, child: Text('hex')),
                  DropdownMenuItem(value: false, child: Text('ascii')),
                ],
                onChanged: (v) => onFormat(v ?? true),
              ),
              const SizedBox(width: 8),
              _toggleChip('自动滚动', autoScroll, onToggleAuto),
              const SizedBox(width: 8),
              _toggleChip('显示发送', showSend, onToggleShowSend),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.clear_all, size: 20),
                tooltip: '清空日志',
                onPressed: engine.clearLogs,
              ),
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
          child: ValueListenableBuilder<List<LogEntry>>(
            valueListenable: engine.logs,
            builder: (_, allLogs, ___) {
              final kw = filterCtl.text;
              final list = allLogs
                  .where((e) => _match(e, kw))
                  .where((e) =>
                      e.dir == LogDir.event ||
                      (showSend
                          ? true
                          : (e.dir != LogDir.sendOk &&
                              e.dir != LogDir.sendFail)))
                  .toList();
              if (autoScroll) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (logScroll.hasClients) {
                    logScroll.jumpTo(logScroll.position.maxScrollExtent);
                  }
                });
              }
              if (list.isEmpty) {
                return const Center(
                    child: Text('暂无日志', style: TextStyle(color: Colors.grey)));
              }
              return ListView.builder(
                controller: logScroll,
                itemCount: list.length,
                itemBuilder: (_, i) => _logLine(list[i]),
              );
            },
          ),
        ),
      ],
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

  Widget _logLine(LogEntry e) {
    final Color dirColor;
    switch (e.dir) {
      case LogDir.notify:
      case LogDir.indicate:
      case LogDir.read:
        dirColor = Colors.green;
        break;
      case LogDir.sendOk:
        dirColor = const Color(0xFFF57C00);
        break;
      case LogDir.sendFail:
        dirColor = Colors.red;
        break;
      case LogDir.event:
        dirColor = Colors.grey;
    }
    final content = e.dir == LogDir.event
        ? e.message ?? ''
        : '${HexUtil.display(e.bytes, hexMode)}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Text.rich(
        TextSpan(
          style:
              const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.3),
          children: [
            TextSpan(text: '${e.timeStr}  ', style: const TextStyle(color: Colors.black54)),
            if (e.tag.isNotEmpty)
              TextSpan(text: '[$e.tag] ', style: const TextStyle(color: Colors.blueGrey)),
            TextSpan(text: '${e.dirStr} ', style: TextStyle(color: dirColor)),
            TextSpan(
              text: content,
              style: TextStyle(color: e.dir == LogDir.event ? Colors.black54 : dirColor),
            ),
          ],
        ),
      ),
    );
  }
}
