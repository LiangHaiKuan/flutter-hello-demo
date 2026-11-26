import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/ble_util.dart';
import '../services/ble_engine.dart';
import '../widgets/log_floating.dart';
import 'device_page.dart';
import 'knowledge_page.dart';

/// 广播数据页（对标原版）：RSSI 曲线图 + 原始数据复制 + LEN/TYPE/VALUE 解析表 + 字符串翻译表
///
/// 注：flutter_blue_plus 1.35 的 AdvertisementData 不带原始字节，
/// 表格和"原始数据"由结构化字段（txPower/appearance/uuids/serviceData/厂商数据）重组。
///
/// v1.2：进页后 RSSI 持续更新（自动扫描 / 已连接设备走 readRssi）。
class AdvDataPage extends StatefulWidget {
  final String mac;
  final String name;
  const AdvDataPage({super.key, required this.mac, required this.name});

  @override
  State<AdvDataPage> createState() => _AdvDataPageState();
}

class _AdvDataPageState extends State<AdvDataPage> {
  final BleEngine _engine = BleEngine.instance;
  Timer? _uiTimer;
  VoidCallback? _rssiListener;
  DeviceSession? _session;

  @override
  void initState() {
    super.initState();
    _session = _engine.sessionOf(widget.mac);
    // 1 秒刷新一次曲线（数据源：扫描广播 / 已连接设备 readRssi）
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    if (_session != null && _session!.isConnected) {
      // 已连接设备：把 readRssi 的值也记进曲线历史
      _rssiListener = () {
        _engine.addRssiSample(widget.mac, _session!.rssi.value);
      };
      _session!.rssi.addListener(_rssiListener!);
    } else if (!_engine.scanning.value) {
      // 页面里要持续画 RSSI 曲线：没在扫描就静默开启（离开页面不主动停，保持数据流）
      FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 60),
        continuousUpdates: true,
        continuousDivisor: 1,
      );
    }
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    if (_session != null && _rssiListener != null) {
      _session!.rssi.removeListener(_rssiListener!);
    }
    super.dispose();
  }

  /// 从结构化字段组装等效的广播数据字节流（AD 结构）
  List<int> _assembleRaw(AdvertisementData? adv) {
    if (adv == null) return const [];
    final out = <int>[];
    void addStruct(int type, List<int> value) {
      if (value.isEmpty) return;
      out.add(value.length + 1); // len = type + value
      out.add(type);
      out.addAll(value);
    }

    // Flags（0x01）：fbp 不给原始 flags，按 connectable 重组（可连接 0x06 / 不可连接 0x05）
    final flagsVal = adv.connectable ? 0x06 : 0x05;
    addStruct(0x01, [flagsVal]);
    // 完整设备名（0x09）
    if (adv.advName.isNotEmpty) {
      addStruct(0x09, adv.advName.codeUnits);
    }
    addStruct(0x0A, [adv.txPowerLevel != null ? adv.txPowerLevel! & 0xFF : 0]);
    if (adv.appearance != null && adv.appearance != 0) {
      final a = adv.appearance!;
      addStruct(0x19, [a & 0xFF, (a >> 8) & 0xFF]);
    }
    adv.serviceUuids.forEach((g) {
      final bytes = _guidBytes(g);
      addStruct(bytes.length == 2 ? 0x02 : 0x07, bytes);
    });
    adv.serviceData.forEach((g, data) {
      addStruct(0x16, [..._guidBytes(g), ...data]);
    });
    adv.manufacturerData.forEach((id, data) {
      addStruct(0xFF, [id & 0xFF, (id >> 8) & 0xFF, ...data]);
    });
    return out;
  }

  List<int> _guidBytes(dynamic g) {
    final u = g.str.toLowerCase().replaceAll('-', '');
    final bytes = <int>[];
    for (var i = u.length - 2; i >= 0; i -= 2) {
      bytes.add(int.parse(u.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  List<_AdStruct> _buildTable(AdvertisementData? adv) {
    if (adv == null) return const [];
    final list = <_AdStruct>[];
    // Flags（0x01）
    final flagsVal = adv.connectable ? 0x06 : 0x05;
    list.add(_AdStruct(
        len: 3,
        type: 0x01,
        value: [flagsVal],
        note: 'Flags · 标志位'));
    // 完整设备名（0x09）
    if (adv.advName.isNotEmpty) {
      list.add(_AdStruct(
          len: adv.advName.length + 1,
          type: 0x09,
          value: adv.advName.codeUnits,
          note: 'Complete Local Name · 完整设备名'));
    }
    if (adv.txPowerLevel != null) {
      list.add(_AdStruct(
          len: 3,
          type: 0x0A,
          value: [adv.txPowerLevel! & 0xFF],
          note: 'Tx Power Level'));
    }
    if (adv.appearance != null && adv.appearance != 0) {
      final a = adv.appearance!;
      list.add(_AdStruct(
          len: 3, type: 0x19, value: [a & 0xFF, (a >> 8) & 0xFF],
          note: 'Appearance'));
    }
    adv.serviceUuids.forEach((g) {
      final bytes = _guidBytes(g);
      list.add(_AdStruct(
          len: bytes.length + 1,
          type: bytes.length == 2 ? 0x02 : 0x07,
          value: bytes,
          note: 'Service UUID'));
    });
    adv.serviceData.forEach((g, data) {
      final b = _guidBytes(g);
      list.add(_AdStruct(
          len: b.length + data.length + 1,
          type: 0x16,
          value: [...b, ...data],
          note: 'Service Data · 服务数据'));
    });
    adv.manufacturerData.forEach((id, data) {
      list.add(_AdStruct(
          len: data.length + 3,
          type: 0xFF,
          value: [id & 0xFF, (id >> 8) & 0xFF, ...data],
          note: 'Manufacturer Data · 厂商自定义数据'));
    });
    return list;
  }

  String _typeName(int t) {
    const names = {
      0x01: 'Flags · 标志位',
      0x02: 'Incomplete 16b UUIDs',
      0x03: 'Complete 16b UUIDs',
      0x06: 'Incomplete 128b UUIDs',
      0x07: 'Complete 128b UUIDs',
      0x08: 'Shortened Local Name · 缩写设备名',
      0x09: 'Complete Local Name · 完整设备名',
      0x0A: 'Tx Power Level · 发射功率',
      0x16: 'Service Data · 服务数据',
      0x19: 'Appearance · 外观标识',
      0xFF: 'Manufacturer Data · 厂商自定义数据',
    };
    return names[t] ?? 'Unknown (0x${t.toRadixString(16).padLeft(2, '0')})';
  }

  /// 直接连接广播设备（广播数据页内）
  Future<void> _connectDevice(BuildContext ctx) async {
    final r = _engine.latestResults[widget.mac];
    if (r == null) {
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
          content: Text('还没有该设备的广播信息'),
          duration: Duration(milliseconds: 800)));
      return;
    }
    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
        content: Text('正在连接...'),
        duration: Duration(milliseconds: 800)));
    await _engine.connect(r.device);
    if (mounted) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DevicePage(mac: widget.mac, name: widget.name),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final adv = _engine.latestResults[widget.mac]?.advertisementData;
    final history = _engine.rssiHistory[widget.mac] ?? const <RssiSample>[];

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('广播数据(${widget.name})',
                style: const TextStyle(fontSize: 17)),
            Text(widget.mac,
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
        actions: [
          // 连接按钮：不用退回主界面再点连接（v1.5）
          Builder(
            builder: (ctx) => TextButton(
              onPressed: () => _connectDevice(ctx),
              child: const Text('连接',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold)),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'kb') {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const KnowledgePage(section: 'adv')));
              }
              if (v == 'log') FloatingLog.instance.toggle(context);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'kb', child: Text('广播包科普')),
              PopupMenuItem(value: 'log', child: Text('悬浮日志')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // ---------- RSSI 曲线 ----------
          _RssiChart(values: history),
          const SizedBox(height: 8),
          const Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.show_chart, color: Color(0xFFF57C00), size: 16),
                SizedBox(width: 4),
                Text('信号强度（持续更新中）',
                    style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ---------- 原始数据（v1.7：长按可复制） ----------
          const Row(
            children: [
              Text('原始数据（长按可复制）:',
                  style: TextStyle(fontSize: 14, color: Colors.black54)),
              const Spacer(),
              TextButton(
                onPressed: () {
                  final text = _rawHex(_assembleRaw(adv));
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('原始广播数据已复制'),
                      duration: Duration(milliseconds: 800)));
                },
                child: const Text('复制',
                    style: TextStyle(color: Color(0xFFF57C00))),
              ),
            ],
          ),
          GestureDetector(
            onLongPress: () =>
                _copySection(context, _rawHex(_assembleRaw(adv)), '原始数据'),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _rawHex(_assembleRaw(adv)),
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 13, height: 1.4),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // ---------- 广播详内容表 ----------
          const Text('广播详内容（长按可复制）:',
              style: TextStyle(fontSize: 14, color: Colors.black54)),
          const SizedBox(height: 6),
          GestureDetector(
            onLongPress: () =>
                _copySection(context, _tableText(adv), '广播详内容'),
            child: _buildTableWidget(adv),
          ),
          const SizedBox(height: 16),
          // ---------- 字符串翻译表（可打印字符绿色显示） ----------
          const Text('字符串翻译视图（长按可复制）:',
              style: TextStyle(fontSize: 14, color: Colors.black54)),
          const SizedBox(height: 2),
          const Text('可打印字符（0~9、a~Z、常用标点）翻译成字符用背景色标出，'
                  '无法翻译的字节保持十六进制',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 6),
          GestureDetector(
            onLongPress: () => _copySection(
                context, _tableText(adv, translated: true), '字符串翻译视图'),
            child: _buildTranslateTable(adv),
          ),
          const SizedBox(height: 16),
          // ---------- v1.6：TYPE 字段中文含义对照（跟在字符串翻译视图下面） ----------
          const Text('字段含义（中文对照）:',
              style: TextStyle(fontSize: 14, color: Colors.black54)),
          const SizedBox(height: 6),
          _buildFieldMeaningBox(),
          const SizedBox(height: 16),
          // ---------- Flags 逐位含义（TYPE=0x01） ----------
          _buildFlagsSection(adv),
          const SizedBox(height: 16),
          // ---------- 广播包解读（面向初学者的白话总结） ----------
          _buildSummarySection(adv),
        ],
      ),
    );
  }

  // ---------- v1.7：长按复制整块文本 ----------
  void _copySection(BuildContext ctx, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text('$label 已复制'),
        duration: const Duration(milliseconds: 800)));
  }

  /// 把解析表转成纯文本，供长按复制（translated=true 时附带可打印字符）
  String _tableText(AdvertisementData? adv, {bool translated = false}) {
    final rows = _buildTable(adv);
    final b = StringBuffer()
      ..writeln('LEN  TYPE  VALUE${translated ? ' (翻译)' : ''}');
    for (final r in rows) {
      String hex = _hex(r.value);
      if (translated) {
        final chars = String.fromCharCodes(
            r.value.where((v) => v >= 0x20 && v <= 0x7E));
        if (chars.isNotEmpty) hex = '$hex  [$chars]';
      }
      b.writeln(
          '${r.len}  0x${r.type.toRadixString(16).padLeft(2, '0')}  $hex  ${r.note ?? _typeName(r.type)}');
    }
    return b.toString();
  }

  // ---------- v1.6：TYPE 字段中文含义对照表 ----------
  Widget _buildFieldMeaningBox() {
    const rows = [
      ('Flags', '标志位（设备能力：可否连接、是否支持经典蓝牙）'),
      ('Complete Local Name', '完整设备名（广播里的蓝牙名称）'),
      ('Shortened Local Name', '缩写设备名（放不下完整名时的缩写）'),
      ('Service Data', '服务数据（随广播附带的服务数据，如 iBeacon）'),
      ('Manufacturer Data', '厂商自定义数据（厂家自己定义的内容）'),
      ('Service UUID', '服务 UUID 列表（设备支持的服务）'),
      ('Tx Power Level', '发射功率（信号强度参考）'),
      ('Appearance', '外观标识（设备图标类别）'),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8F0),
        border: Border.all(color: Colors.orange.shade200),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (en, cn) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text.rich(
                TextSpan(
                  style: const TextStyle(fontSize: 12),
                  children: [
                    TextSpan(
                        text: en,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFF57C00))),
                    const TextSpan(text: '  =  '),
                    TextSpan(text: cn),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------- Flags 逐位含义 ----------
  Widget _buildFlagsSection(AdvertisementData? adv) {
    final flags = adv?.connectable == true ? 0x06 : 0x05;
    const bitDefs = [
      (0x01, 'LE Limited Discoverable', '有限可发现模式（短暂广播几秒钟）'),
      (0x02, 'LE General Discoverable', '通用可发现模式（正常持续广播）'),
      (0x04, 'BR/EDR Not Supported', '不支持经典蓝牙（纯 BLE 设备）'),
      (0x08, 'Simultaneous LE+BR/EDR (Ctrl)', '控制器层同时支持 BLE + 经典蓝牙'),
      (0x10, 'Simultaneous LE+BR/EDR (Host)', '主机层同时支持 BLE + 经典蓝牙'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Flags（TYPE=0x01）逐位含义:',
            style: TextStyle(fontSize: 14, color: Colors.black54)),
        const SizedBox(height: 2),
        Text('本设备 Flags = 0x${flags.toRadixString(16).padLeft(2, '0')}，'
                '对应勾选了下面加粗的位：',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 6),
        Table(
          border: TableBorder.all(color: Colors.grey.shade400, width: 0.5),
          columnWidths: const {
            0: FlexColumnWidth(1),
            1: FlexColumnWidth(2.4),
            2: FlexColumnWidth(3.6),
          },
          children: [
            const TableRow(
              decoration: BoxDecoration(color: Color(0xFFF5F5F5)),
              children: [
                Padding(padding: EdgeInsets.all(6), child: Text('位',
                    style: TextStyle(fontSize: 13, color: Colors.orange))),
                Padding(padding: EdgeInsets.all(6), child: Text('名称',
                    style: TextStyle(fontSize: 13, color: Colors.orange))),
                Padding(padding: EdgeInsets.all(6), child: Text('含义',
                    style: TextStyle(fontSize: 13, color: Colors.orange))),
              ],
            ),
            for (final d in bitDefs)
              TableRow(children: [
                Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text('0x${d.$1.toRadixString(16).padLeft(2, '0')}',
                        style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            fontWeight: (flags & d.$1) != 0
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: (flags & d.$1) != 0
                                ? const Color(0xFFF57C00)
                                : Colors.grey))),
                Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(d.$2,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: (flags & d.$1) != 0
                                ? FontWeight.bold
                                : FontWeight.normal))),
                Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(d.$3,
                        style: const TextStyle(fontSize: 11))),
              ]),
          ],
        ),
      ],
    );
  }

  // ---------- 广播包解读（白话总结：这个设备可能是什么、在干什么） ----------
  Widget _buildSummarySection(AdvertisementData? adv) {
    if (adv == null) return const SizedBox.shrink();
    final bullets = <String>[];

    // 名称解读
    final name = adv.advName;
    if (name.isNotEmpty) {
      bullets.add('设备名「$name」——扫描列表里显示的就是它。');
    }
    // Flags
    bullets.add(adv.connectable
        ? 'Flags=0x06：这是一台「可连接的 BLE 设备」，正在等待别人来连接，同时不支持经典蓝牙。'
        : 'Flags=0x05：这是一台「只广播不让人连的设备」（信标类，如传感器标签）。');
    // 服务 UUID
    if (adv.serviceUuids.isNotEmpty) {
      final names = adv.serviceUuids
          .map((g) => UuidNames.serviceName(g.str))
          .join('、');
      bullets.add('广播的服务：$names ——声明"我能提供这些服务"。看到熟悉的服务'
          '（如 Battery 0x180F）就能猜出设备用途。');
    }
    // 服务数据
    adv.serviceData.forEach((g, data) {
      bullets.add('服务数据（${UuidNames.serviceName(g.str)}）：'
          '${HexUtil.toHex(data)} ——通常是该服务的实时数据'
          '（如电量、传感器读数），格式由服务定义决定。');
    });
    // 厂商数据
    adv.manufacturerData.forEach((id, data) {
      bullets.add('厂商自定义数据（厂商ID=0x${id.toRadixString(16).padLeft(4, '0').toUpperCase()}）：'
          '${HexUtil.toHex(data)} ——格式厂家自己定，只有拿到他家协议文档才能完全解析；'
          '常见用途：设备状态、传感器数据、iBeacon 定位、防丢器等。');
    });
    // 外观
    if (adv.appearance != null && adv.appearance != 0) {
      bullets.add('外观码 Appearance=0x${adv.appearance!.toRadixString(16)}：'
          '蓝牙联盟分配的图标类别，可按码表查到设备大类（手环/鼠标/温度计等）。');
    }
    // 发射功率
    if (adv.txPowerLevel != null) {
      bullets.add('发射功率 ${adv.txPowerLevel} dBm：配合手机收到的 RSSI '
          '（RSSI - 发射功率 ≈ 路径损耗）可以粗略估算距离。');
    }
    // 设备类型推测
    String guess = '从以上信息推测：';
    final n = name.toLowerCase();
    if (adv.serviceUuids.map((g) => g.str).any((u) => u.contains('180f'))) {
      guess += '带电量服务，';
    }
    if (n.contains('watch') || n.contains('band') || n.contains('ring')) {
      guess += '名字含手表/手环关键词，多半是「穿戴设备」。';
    } else if (adv.manufacturerData.isNotEmpty && n.isNotEmpty) {
      guess += '带厂商自定义数据且持续广播，多半是「传感器/信标类设备」'
          '（如温湿度计、防丢器、工卡）。';
    } else if (adv.connectable) {
      guess += '可连接的 BLE 外设，用途要连上后看服务列表才能确定。';
    }
    bullets.add(guess);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('广播包解读（白话版）:',
            style: const TextStyle(fontSize: 14, color: Colors.black54)),
        const SizedBox(height: 2),
        const Text('按蓝牙联盟规范的通用含义逐条解读，初学者可以照着对照学习',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 6),
        for (final b in bullets)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• ',
                    style:
                        TextStyle(fontSize: 12, color: Color(0xFFF57C00))),
                Expanded(
                  child: Text(b,
                      style: const TextStyle(fontSize: 12, height: 1.4)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildTableWidget(AdvertisementData? adv) {
    final rows = _buildTable(adv);
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('暂无广播数据（等待新的广播包）',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
      );
    }
    return Table(
      border: TableBorder.all(color: Colors.grey.shade400, width: 0.5),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: const {
        0: FlexColumnWidth(1),
        1: FlexColumnWidth(1.4),
        2: FlexColumnWidth(4),
      },
      children: [
        _headerRow(),
        for (final r in rows)
          TableRow(
            children: [
              Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text('${r.len}',
                      style: const TextStyle(fontSize: 13))),
              Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text('0x${r.type.toRadixString(16).padLeft(2, '0')}',
                      style: const TextStyle(fontSize: 13))),
              Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_hex(r.value),
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13)),
                      Text(r.note ?? _typeName(r.type),
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600)),
                    ],
                  )),
            ],
          ),
      ],
    );
  }

  /// 字符串翻译表：VALUE 里可打印 ASCII 用绿色字符显示
  Widget _buildTranslateTable(AdvertisementData? adv) {
    final rows = _buildTable(adv);
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('暂无广播数据',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
      );
    }
    return Table(
      border: TableBorder.all(color: Colors.grey.shade400, width: 0.5),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: const {
        0: FlexColumnWidth(1),
        1: FlexColumnWidth(1.4),
        2: FlexColumnWidth(4),
      },
      children: [
        _headerRow('VALUE (翻译)'),
        for (final r in rows)
          TableRow(
            children: [
              Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text('${r.len}',
                      style: const TextStyle(fontSize: 13))),
              Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text('0x${r.type.toRadixString(16).padLeft(2, '0')}',
                      style: const TextStyle(fontSize: 13))),
              Padding(
                  padding: const EdgeInsets.all(6),
                  child: Wrap(
                    spacing: 3,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final b in r.value) _translatedByte(b),
                    ],
                  )),
            ],
          ),
      ],
    );
  }

  TableRow _headerRow([String valueTitle = 'VALUE']) {
    return TableRow(
      decoration: const BoxDecoration(color: Color(0xFFF5F5F5)),
      children: [
        const Padding(
            padding: EdgeInsets.all(6),
            child: Text('LEN',
                style: TextStyle(fontSize: 13, color: Colors.orange))),
        const Padding(
            padding: EdgeInsets.all(6),
            child: Text('TYPE',
                style: TextStyle(fontSize: 13, color: Colors.orange))),
        Padding(
            padding: const EdgeInsets.all(6),
            child: Text(valueTitle,
                style: const TextStyle(fontSize: 13, color: Colors.orange))),
      ],
    );
  }

  /// 单字节翻译：可打印 ASCII（0x20~0x7E）→ 文字加背景色；否则黑色 hex
  Widget _translatedByte(int b) {
    final printable = b >= 0x20 && b <= 0x7E;
    if (printable) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFFFE0B2), // 淡橙背景：翻译出来的字符
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          String.fromCharCode(b),
          style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
              fontFamily: 'monospace'),
        ),
      );
    }
    return Text(
      b.toRadixString(16).padLeft(2, '0').toUpperCase(),
      style: const TextStyle(
          fontSize: 13,
          color: Colors.black87,
          fontFamily: 'monospace'),
    );
  }

  String _hex(List<int> b) => b
      .map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  String _rawHex(List<int> b) => b
      .map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();
}

class _AdStruct {
  final int len; // len 字节值（type+value 的长度）
  final int type;
  final List<int> value;
  final String? note;
  _AdStruct({required this.len, required this.type, required this.value,
      this.note});
}

// ---------------- RSSI 折线图（自绘，无第三方依赖） ----------------
// v1.5：横轴改为时间轴 0~40 秒滑动窗口（每 10 秒一格），数据点按采样时刻落位，
// 超过 40 秒的旧数据移出窗口。
class _RssiChart extends StatelessWidget {
  final List<RssiSample> values;
  const _RssiChart({required this.values});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 220,
      child: CustomPaint(
        painter: _RssiPainter(values: values),
        child: Container(),
      ),
    );
  }
}

class _RssiPainter extends CustomPainter {
  final List<RssiSample> values;
  _RssiPainter({required this.values});

  static const double windowSec = 40;

  @override
  void paint(Canvas canvas, Size size) {
    const top = -20.0, bottom = -100.0;
    const padL = 36.0, padR = 36.0, padT = 8.0, padB = 18.0;
    final chartW = size.width - padL - padR;
    final chartH = size.height - padT - padB;

    final gridPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 1;
    final linePaint = Paint()
      ..color = const Color(0xFFF57C00)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final textStyle = TextStyle(fontSize: 10, color: Colors.grey.shade600);

    // 纵轴：-100 到 -20，每 10dBm 一格
    for (var v = -20; v >= bottom; v -= 10) {
      final y = padT + (top - v) / (top - bottom) * chartH;
      canvas.drawLine(
          Offset(padL, y), Offset(size.width - padR, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: '$v', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(padL - tp.width - 4, y - tp.height / 2));
      tp.paint(canvas, Offset(size.width - padR + 4, y - tp.height / 2));
    }
    // 横轴：0 ~ 40 秒，每 10 秒一格
    canvas.drawLine(Offset(padL, padT), Offset(padL, size.height - padB),
        axisPaint);
    canvas.drawLine(Offset(padL, size.height - padB),
        Offset(size.width - padR, size.height - padB), axisPaint);
    for (var sec = 0; sec <= 40; sec += 10) {
      final x = padL + chartW * sec / windowSec;
      canvas.drawLine(Offset(x, padT), Offset(x, size.height - padB), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: '${sec}s', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          Offset(x - tp.width / 2, size.height - padB + 2));
    }

    if (values.isEmpty) {
      final tp = TextPainter(
        text: const TextSpan(text: '等待广播数据...',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
      return;
    }

    // 数据点：按"距现在多少秒"落位，0s 在最右侧（滚动窗口）
    final now = DateTime.now();
    final path = Path();
    var first = true;
    for (final s in values) {
      final age = now.difference(s.t).inMilliseconds / 1000.0;
      if (age > windowSec) continue;
      final x = padL + chartW * (1 - age / windowSec);
      final v = s.v.clamp(bottom.toInt(), top.toInt()).toDouble();
      final y = padT + (top - v) / (top - bottom) * chartH;
      if (first) {
        path.moveTo(x, y);
        first = false;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _RssiPainter old) => true; // 每 1 秒 setState 重绘
}
