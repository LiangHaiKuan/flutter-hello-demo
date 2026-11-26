import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/ble_util.dart';
import '../core/notepad_client.dart';
import '../models/models.dart';
import '../services/ble_engine.dart';
import '../widgets/log_floating.dart';

/// 自定义按键：命令增删改、发送、导入导出（含云端同步）
///
/// v1.3：
/// - 底部常驻按钮条移除，导入/导出/添加全部收进右上角三点菜单；
/// - 列表支持勾选（多选/全选），导出只导出勾选的，不勾选不导出；
/// - 导入按 fast_cmds 格式逐行匹配，不匹配的行跳过，`//` 为注释行；
///   导入前弹确认列表（勾选确认，重复的自动覆盖），完成后提示导入条数；
/// - 云端同步：1paper 云端 txt 全量读取 / 全量覆盖写入，支持链接1/2/3...
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
        SnackBar(content: Text(msg), duration: const Duration(milliseconds: 900)));
  }

  // ---------- 添加 / 修改 ----------
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
                // 多行自适应：1 行内容显示 1 行高，最多撑到 4 行，再多内部滚动
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
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

  // ---------- 发送 ----------
  Future<void> _sendCmd(FastCmd c) async {
    final sessions = _engine.sessionList;
    if (sessions.isEmpty) {
      _toast('没有已连接的设备');
      return;
    }
    final bytes = HexUtil.parse(c.data, c.hexMode ? TextCodec.hex : TextCodec.ascii);
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

  Future<void> _sendSelected() async {
    final list =
        _engine.cmds.where((c) => _selected.contains(c.id)).toList();
    if (list.isEmpty) {
      _toast('请先勾选要发送的命令');
      return;
    }
    final sessions = _engine.sessionList;
    if (sessions.isEmpty) {
      _toast('没有已连接的设备');
      return;
    }
    for (final c in list) {
      final bytes = HexUtil.parse(c.data, c.hexMode ? TextCodec.hex : TextCodec.ascii);
      if (bytes == null) continue;
      for (final s in sessions) {
        await s.send(bytes, false, recordHistory: false);
      }
    }
    _toast('已发送 ${list.length} 条命令');
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) {
      _toast('请先勾选要删除的命令');
      return;
    }
    _engine.cmds.removeWhere((c) => _selected.contains(c.id));
    for (var i = 0; i < _engine.cmds.length; i++) {
      _engine.cmds[i].order = i;
    }
    await _engine.saveCmds();
    _engine.cmdsBump.value++;
    setState(() => _selected.clear());
  }

  // ---------- 导出（只导出勾选的） ----------
  List<FastCmd>? _checkedCmds() {
    final list = _engine.cmds.where((c) => _selected.contains(c.id)).toList();
    if (list.isEmpty) {
      _toast('请先勾选要导出的命令（不勾选不导出）');
      return null;
    }
    return list;
  }

  void _exportToClipboard() {
    final list = _checkedCmds();
    if (list == null) return;
    final text = list
        .asMap()
        .entries
        .map((e) => e.value.exportLine(e.key + 1))
        .join('\n');
    Clipboard.setData(ClipboardData(text: text));
    _toast('已导出 ${list.length} 条命令到剪贴板（fast_cmds 格式）');
  }

  Future<void> _exportToFile() async {
    final list = _checkedCmds();
    if (list == null) return;
    try {
      final text = list
          .asMap()
          .entries
          .map((e) => e.value.exportLine(e.key + 1))
          .join('\n');
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = await FilePicker.platform.saveFile(
        fileName: 'fast_cmds_$ts.txt',
        bytes: Uint8List.fromList(utf8.encode(text)),
      );
      if (path != null) _toast('已保存到 $path');
    } catch (e) {
      _toast('导出失败: $e');
    }
  }

  // ---------- 导入（解析 → 勾选确认 → 合并，重复自动覆盖） ----------
  Future<void> _confirmImport(FastCmdParseResult parsed, String sourceName) async {
    if (parsed.cmds.isEmpty) {
      _toast('$sourceName 没有符合 fast_cmds 格式的指令'
          '（解析了 0 条，跳过 ${parsed.skippedLines} 行）');
      return;
    }
    final checked = {for (var i = 0; i < parsed.cmds.length; i++) i};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('确认导入（$sourceName）'),
          content: SizedBox(
            width: double.maxFinite,
            height: 360,
            child: Column(
              children: [
                Text(
                  '找到 ${parsed.cmds.length} 条指令，'
                  '跳过 ${parsed.skippedLines} 行（注释/格式不符）。'
                  '勾选要导入的，重复名称自动覆盖：',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setD(() {
                        if (checked.length == parsed.cmds.length) {
                          checked.clear();
                        } else {
                          checked
                            ..clear()
                            ..addAll(List.generate(parsed.cmds.length, (i) => i));
                        }
                      }),
                      child: Text(checked.length == parsed.cmds.length
                          ? '全不选'
                          : '全选'),
                    ),
                  ],
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: parsed.cmds.length,
                    itemBuilder: (_, i) {
                      final c = parsed.cmds[i];
                      return CheckboxListTile(
                        dense: true,
                        value: checked.contains(i),
                        activeColor: const Color(0xFFF57C00),
                        title: Text(c.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(c.preview(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, fontFamily: 'monospace')),
                        onChanged: (v) =>
                            setD(() => v == true ? checked.add(i) : checked.remove(i)),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('导入 ${checked.length} 条')),
          ],
        ),
      ),
    );
    if (ok != true || checked.isEmpty) return;

    // 合并：重名自动覆盖，其余追加
    var overwritten = 0, added = 0;
    for (final i in checked) {
      final c = parsed.cmds[i];
      final existing =
          _engine.cmds.where((e) => e.name == c.name).toList();
      if (existing.isNotEmpty) {
        existing.first.data = c.data;
        existing.first.hexMode = c.hexMode;
        overwritten++;
      } else {
        c.order = _engine.cmds.length;
        _engine.cmds.add(c);
        added++;
      }
    }
    for (var i = 0; i < _engine.cmds.length; i++) {
      _engine.cmds[i].order = i;
    }
    await _engine.saveCmds();
    _engine.cmdsBump.value++;
    setState(() {});
    _toast('导入完成：新增 $added 条，覆盖 $overwritten 条');
  }

  Future<void> _importFromFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'cmds'],
      );
      if (res == null || res.files.isEmpty) return;
      final path = res.files.single.path;
      if (path == null) {
        _toast('无法读取所选文件');
        return;
      }
      final raw = await File(path).readAsString();
      await _confirmImport(parseFastCmds(raw), '文件导入');
    } catch (e) {
      _toast('导入失败: $e');
    }
  }

  Future<void> _importFromClipboard() async {
    final text = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = text?.text ?? '';
    if (raw.trim().isEmpty) {
      _toast('剪贴板没有内容，请先复制 fast_cmds 格式文本');
      return;
    }
    await _confirmImport(parseFastCmds(raw), '剪贴板导入');
  }

  // ---------- 云端同步 ----------
  Future<void> _cloudRead(String link) async {
    _toast('正在读取云端...');
    _engine.logEvent('', '云端读取开始: $link');
    final client = NotepadClient();
    client.onLog = (m) => _engine.logEvent('', '云端: $m');
    try {
      final text = await client.readNote(link);
      await _confirmImport(parseFastCmds(text), '云端读取');
    } catch (e) {
      _engine.logEvent('', '云端读取失败: $e');
      _toast('云端读取失败: $e');
    } finally {
      client.dispose();
    }
  }

  Future<void> _cloudWrite(String link) async {
    final list = _checkedCmds();
    if (list == null) return;
    final text = list
        .asMap()
        .entries
        .map((e) => e.value.exportLine(e.key + 1))
        .join('\n');
    _toast('正在覆盖写入云端...');
    _engine.logEvent('', '云端写入开始: $link（${list.length} 条）');
    final client = NotepadClient();
    client.onLog = (m) => _engine.logEvent('', '云端: $m');
    try {
      await client.writeNote(link, text);
      _engine.logEvent('', '云端写入成功: ${list.length} 条');
      _toast('云端已覆盖写入 ${list.length} 条命令');
    } catch (e) {
      _engine.logEvent('', '云端写入失败: $e');
      _toast('云端写入失败: $e');
    } finally {
      client.dispose();
    }
  }

  /// 选择一个云端链接（链接1/2/3...）
  Future<String?> _pickCloudLink(BuildContext ctx) async {
    final links = _engine.cloudLinks;
    if (links.isEmpty) {
      _toast('还没有配置云端链接，请先到「云端链接配置」添加');
      return null;
    }
    if (links.length == 1) return links.first;
    return showModalBottomSheet<String>(
      context: ctx,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('选择云端链接',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (var i = 0; i < links.length; i++)
              ListTile(
                leading: Text('链接${i + 1}'),
                title: Text(links[i],
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(c, links[i]),
              ),
          ],
        ),
      ),
    );
  }

  /// 云端链接配置：增删改链接（链接1/2/3...）
  Future<void> _editCloudLinks() async {
    final links = List<String>.from(_engine.cloudLinks);
    await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('云端链接配置'),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('云端 txt 文档链接（1paper 等支持链接），'
                          '链接1/2/3 可对应不同项目：',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: links.length,
                    itemBuilder: (_, i) => ListTile(
                      dense: true,
                      leading: Text('链接${i + 1}'),
                      title: TextFormField(
                        initialValue: links[i],
                        maxLines: 2,
                        style: const TextStyle(fontSize: 12),
                        onChanged: (v) => links[i] = v,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.redAccent),
                        onPressed: () => setD(() => links.removeAt(i)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => setD(() => links.add('')),
                child: const Text('添加链接')),
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
    _engine.cloudLinks =
        links.where((l) => l.trim().isNotEmpty).toList();
    await _engine.saveCloudLinks();
    _toast('云端链接已保存（共 ${_engine.cloudLinks.length} 个）');
  }

  // ---------- AppBar 三点菜单 ----------
  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            // 编辑按钮从标题栏挪进三点菜单（v1.5）
            ListTile(
              leading: const Icon(Icons.edit, color: Color(0xFFF57C00)),
              title: Text(_editMode ? '退出编辑模式' : '编辑模式（勾选/删除/拖动排序）'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _editMode = !_editMode;
                  _selected.clear();
                });
              },
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('命令操作',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            ListTile(
              leading:
                  const Icon(Icons.add_circle, color: Color(0xFFF57C00)),
              title: const Text('添加命令'),
              onTap: () {
                Navigator.pop(ctx);
                _editCmd();
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.select_all, color: Color(0xFFF57C00)),
              title: Text(_allSelected ? '全不选' : '全选'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  if (_allSelected) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(_engine.cmds.map((c) => c.id));
                  }
                });
              },
            ),
            if (_editMode)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.redAccent),
                title: const Text('删除勾选的命令',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteSelected();
                },
              ),
            if (_editMode)
              ListTile(
                leading:
                    const Icon(Icons.send, color: Color(0xFFF57C00)),
                title: const Text('发送勾选的命令'),
                onTap: () {
                  Navigator.pop(ctx);
                  _sendSelected();
                },
              ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('导入 / 导出（只处理勾选的）',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            ListTile(
              leading:
                  const Icon(Icons.folder_open, color: Color(0xFFF57C00)),
              title: const Text('从文件导入'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_paste,
                  color: Color(0xFFF57C00)),
              title: const Text('从剪贴板导入'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromClipboard();
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.file_download, color: Color(0xFFF57C00)),
              title: const Text('导出到文件（勾选）'),
              onTap: () {
                Navigator.pop(ctx);
                _exportToFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_copy,
                  color: Color(0xFFF57C00)),
              title: const Text('导出到剪贴板（勾选）'),
              onTap: () {
                Navigator.pop(ctx);
                _exportToClipboard();
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('云端同步',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            ListTile(
              leading:
                  const Icon(Icons.cloud_download, color: Color(0xFFF57C00)),
              title: const Text('云端读取（全部读取 → 勾选导入）'),
              onTap: () async {
                Navigator.pop(ctx);
                final link = await _pickCloudLink(context);
                if (link != null) _cloudRead(link);
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud_upload, color: Color(0xFFF57C00)),
              title: const Text('云端写入（勾选 → 全量覆盖）'),
              onTap: () async {
                Navigator.pop(ctx);
                final link = await _pickCloudLink(context);
                if (link != null) _cloudWrite(link);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.settings, color: Color(0xFFF57C00)),
              title: const Text('云端链接配置'),
              onTap: () {
                Navigator.pop(ctx);
                _editCloudLinks();
              },
            ),
            const Divider(),
            ListTile(
              leading: Icon(
                Icons.picture_in_picture,
                color: FloatingLog.instance.isShowing
                    ? Colors.green
                    : const Color(0xFFF57C00),
              ),
              title: const Text('悬浮日志'),
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

  bool get _allSelected =>
      _engine.cmds.isNotEmpty && _selected.length == _engine.cmds.length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        title: const Text('自定义按键'),
        actions: [
          // 编辑按钮已挪进右上角三点菜单（v1.5）
          IconButton(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              tooltip: '更多',
              onPressed: _showMoreMenu),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _engine.cmdsBump,
        builder: (_, __, ___) {
          final cmds = _engine.cmds;
          if (cmds.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('还没有命令，右上角三点菜单里可以导入',
                      style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF57C00),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _importFromFile,
                    icon: const Icon(Icons.file_open),
                    label: const Text('从文件导入指令'),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _editCmd,
                    icon: const Icon(Icons.add),
                    label: const Text('手动添加一条'),
                  ),
                ],
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '已选 ${_selected.length}/${cmds.length} 条'
                    '（导出/云端写入只处理勾选的）　'
                    '单击修改；长按拖动排序；长按数据可复制',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey),
                  ),
                ),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  itemCount: cmds.length,
                  onReorder: (oldI, newI) async {
                    setState(() {
                      if (newI > oldI) newI--;
                      final c = cmds.removeAt(oldI);
                      cmds.insert(newI, c);
                      for (var i = 0; i < cmds.length; i++) {
                        cmds[i].order = i;
                      }
                    });
                    await _engine.saveCmds();
                    _engine.cmdsBump.value++;
                  },
                  itemBuilder: (_, i) {
                    final c = cmds[i];
                    final selected = _selected.contains(c.id);
                    return Card(
                      key: ValueKey(c.id),
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        child: Row(
                          children: [
                            Checkbox(
                              value: selected,
                              activeColor: const Color(0xFFF57C00),
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
                                onTap: () =>
                                    _editMode ? null : _editCmd(c),
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
                                    InkWell(
                                      onLongPress: () {
                                        Clipboard.setData(ClipboardData(
                                            text: c.hexMode
                                                ? c.data
                                                    .toUpperCase()
                                                    .replaceAll(' ', '')
                                                : c.data));
                                        _toast('数据已复制，可粘贴到发送输入框');
                                      },
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          '数据: ${c.preview()}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey,
                                              fontFamily: 'monospace'),
                                        ),
                                      ),
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
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
