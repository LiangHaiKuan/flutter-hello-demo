import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/ble_util.dart';
import '../models/models.dart';
import '../services/ble_engine.dart';

/// 自定义按键：命令增删改、发送、导入导出
class FastCmdPage extends StatefulWidget {
  const FastCmdPage({super.key});

  @override
  State<FastCmdPage> createState() => _FastCmdPageState();
}

class _FastCmdPageState extends State<FastCmdPage> {
  final BleEngine _engine = BleEngine.instance;
  bool _editMode = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _engine.loadCmds();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(milliseconds: 800)));
  }

  Future<void> _editCmd([FastCmd? cmd]) async {
    final nameCtl = TextEditingController(text: cmd?.name ?? '');
    final dataCtl = TextEditingController(text: cmd?.data ?? '');
    bool hexMode = cmd?.hexMode ?? true;
    bool enabled = cmd?.enabled ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(cmd == null ? '添加命令' : '修改命令'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: dataCtl,
                decoration: InputDecoration(
                  labelText: hexMode ? '数据（hex，支持空格）' : '数据（ascii 文本）',
                ),
                maxLines: 2,
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
                  const Spacer(),
                  const Text('启用'),
                  Checkbox(value: enabled, onChanged: (v) => setD(() => enabled = v ?? true)),
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
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (nameCtl.text.trim().isEmpty || dataCtl.text.trim().isEmpty) {
      _toast('名称和数据不能为空');
      return;
    }
    setState(() {
      if (cmd == null) {
        _engine.cmds.add(FastCmd(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: nameCtl.text.trim(),
          hexMode: hexMode,
          data: dataCtl.text.trim(),
          enabled: enabled,
          order: _engine.cmds.length,
        ));
      } else {
        cmd.name = nameCtl.text.trim();
        cmd.data = dataCtl.text.trim();
        cmd.hexMode = hexMode;
        cmd.enabled = enabled;
      }
    });
    await _engine.saveCmds();
    _engine.cmdsBump.value++;
  }

  Future<void> _sendCmd(FastCmd c) async {
    final sessions = _engine.sessionList;
    if (sessions.isEmpty) {
      _toast('没有已连接的设备');
      return;
    }
    final bytes = HexUtil.parse(c.data, c.hexMode);
    if (bytes == null) {
      _toast('数据格式错误');
      return;
    }
    var okCount = 0;
    for (final s in sessions) {
      if (await s.send(bytes, false, recordHistory: false)) okCount++;
    }
    _toast('已发送到 $okCount 台设备');
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    _engine.cmds.removeWhere((c) => _selected.contains(c.id));
    for (var i = 0; i < _engine.cmds.length; i++) {
      _engine.cmds[i].order = i;
    }
    await _engine.saveCmds();
    _engine.cmdsBump.value++;
    setState(() => _selected.clear());
  }

  Future<void> _sendSelected() async {
    final list =
        _engine.cmds.where((c) => _selected.contains(c.id)).toList();
    if (list.isEmpty) return;
    final sessions = _engine.sessionList;
    if (sessions.isEmpty) {
      _toast('没有已连接的设备');
      return;
    }
    for (final c in list) {
      final bytes = HexUtil.parse(c.data, c.hexMode);
      if (bytes == null) continue;
      for (final s in sessions) {
        await s.send(bytes, false, recordHistory: false);
      }
    }
    _toast('已发送 ${list.length} 条命令');
  }

  void _exportCmds() {
    final text = _engine.cmds
        .asMap()
        .entries
        .map((e) => e.value.exportLine(e.key + 1))
        .join('\n');
    Clipboard.setData(Clipboard.setText(text));
    _toast('已导出 ${_engine.cmds.length} 条命令到剪贴板（fast_cmds 格式，可直接粘贴保存为 txt）');
  }

  Future<void> _importCmds() async {
    final text = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = text?.text ?? '';
    if (raw.trim().isEmpty) {
      _toast('剪贴板没有内容，请先复制 fast_cmds 格式文本');
      return;
    }
    final parsed = parseFastCmds(raw);
    if (parsed.isEmpty) {
      _toast('剪贴板内容不是有效的 fast_cmds 格式');
      return;
    }
    final base = _engine.cmds.length;
    for (var i = 0; i < parsed.length; i++) {
      parsed[i].order = base + i;
    }
    _engine.cmds.addAll(parsed);
    await _engine.saveCmds();
    _engine.cmdsBump.value++;
    _toast('导入 ${parsed.length} 条命令');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        title: const Text('自定义按键'),
        actions: [
          IconButton(
              icon: const Icon(Icons.add), tooltip: '添加', onPressed: _editCmd),
          TextButton(
              onPressed: _importCmds,
              child: const Text('导入', style: TextStyle(color: Colors.white))),
          TextButton(
              onPressed: () {
                setState(() => _editMode = !_editMode);
                _selected.clear();
              },
              child: Text(_editMode ? '取消' : '编辑',
                  style: const TextStyle(color: Colors.white))),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _engine.cmdsBump,
        builder: (_, __, ___) {
          final cmds = _engine.cmds;
          if (cmds.isEmpty) {
            return const Center(
                child: Text('还没有命令，点右上角 + 添加',
                    style: TextStyle(color: Colors.grey)));
          }
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '操作提示：单击修改；长按将数据填入发送输入框',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: cmds.length,
                  itemBuilder: (_, i) {
                    final c = cmds[i];
                    final selected = _selected.contains(c.id);
                    return GestureDetector(
                      onLongPress: () {
                        Clipboard.setData(Clipboard.setText(
                            c.hexMode
                                ? c.data.toUpperCase().replaceAll(' ', '')
                                : c.data));
                        _toast('数据已复制，可粘贴到发送输入框');
                      },
                      child: Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 8),
                          child: Row(
                            children: [
                              Checkbox(
                                value: selected,
                                onChanged: (v) => setState(() {
                                  if (v == true) {
                                    _selected.add(c.id);
                                  } else {
                                    _selected.remove(c.id);
                                  }
                                }),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF57C00),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  c.hexMode ? 'hex' : 'ascii',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 10),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: InkWell(
                                  onTap: () => _editMode
                                      ? null
                                      : _editCmd(c),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(c.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 2),
                                      Text(
                                        '数据: ${c.preview()}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey,
                                            fontFamily: 'monospace'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (!_editMode)
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        const Color(0xFFF57C00),
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(52, 32),
                                  ),
                                  onPressed: () => _sendCmd(c),
                                  child: const Text('发送',
                                      style: TextStyle(fontSize: 13)),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: _editMode
          ? Container(
              color: Colors.white,
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 8,
                  top: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton(
                      onPressed: () => setState(() => _selected.clear()),
                      child: const Text('全不选')),
                  TextButton(
                      onPressed: _deleteSelected,
                      child: const Text('删除',
                          style: TextStyle(color: Colors.red))),
                  TextButton(
                      onPressed: _sendSelected,
                      child: const Text('发送')),
                  TextButton(
                      onPressed: _exportCmds,
                      child: const Text('导出命令')),
                ],
              ),
            )
          : null,
    );
  }
}
