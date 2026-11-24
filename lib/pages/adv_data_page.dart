import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../services/ble_engine.dart';
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
        final v = _session!.rssi.value;
        if (v > 0) {
          final h = _engine.rssiHistory.putIfAbsent(widget.mac, () => []);
          h.add(v);
          if (h.length > 300) h.removeRange(0, h.length - 300);
        }
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
          note: 'Service Data'));
    });
    adv.manufacturerData.forEach((id, data) {
      list.add(_AdStruct(
          len: data.length + 3,
          type: 0xFF,
          value: [id & 0xFF, (id >> 8) & 0xFF, ...data],
          note: 'Manufacturer Data'));
    });
    return list;
  }

  String _typeName(int t) {
    const names = {
      0x01: 'Flags',
      0x02: 'Incomplete 16b UUIDs',
      0x03: 'Complete 16b UUIDs',
      0x06: 'Incomplete 128b UUIDs',
      0x07: 'Complete 128b UUIDs',
      0x08: 'Shortened Local Name',
      0x09: 'Complete Local Name',
      0x0A: 'Tx Power Level',
      0x16: 'Service Data - 16b UUID',
      0x19: 'Appearance',
      0xFF: 'Manufacturer Data',
    };
    return names[t] ?? 'Unknown (0x${t.toRadixString(16).padLeft(2, '0')})';
  }

  @override
  Widget build(BuildContext context) {
    final adv = _engine.latestResults[widget.mac]?.advertisementData;
    final history = _engine.rssiHistory[widget.mac] ?? const <int>[];

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        title: Text('广播数据(${widget.name})',
            style: const TextStyle(fontSize: 17)),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'kb') {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const KnowledgePage(section: 'adv')));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'kb', child: Text('广播包科普')),
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
          // ---------- 原始数据 ----------
          Row(
            children: [
              const Text('原始数据:',
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
          Container(
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
          const SizedBox(height: 16),
          // ---------- 广播详内容表 ----------
          const Text('广播详内容:',
              style: TextStyle(fontSize: 14, color: Colors.black54)),
          const SizedBox(height: 6),
          _buildTableWidget(adv),
          const SizedBox(height: 16),
          // ---------- 字符串翻译表（可打印字符绿色显示） ----------
          const Text('字符串翻译视图:',
              style: TextStyle(fontSize: 14, color: Colors.black54)),
          const SizedBox(height: 2),
          const Text('可打印字符（0~9、a~Z、常用标点）翻译成字符用绿色显示，'
                  '无法翻译的字节保持黑色十六进制',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 6),
          _buildTranslateTable(adv),
        ],
      ),
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

  /// 单字节翻译：可打印 ASCII（0x20~0x7E）→ 绿色字符；否则黑色 hex
  Widget _translatedByte(int b) {
    final printable = b >= 0x20 && b <= 0x7E;
    if (printable) {
      return Text(
        String.fromCharCode(b),
        style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Color(0xFF2E7D32), // 绿色
            fontFamily: 'monospace'),
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
class _RssiChart extends StatelessWidget {
  final List<int> values;
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
  final List<int> values;
  _RssiPainter({required this.values});

  @override
  void paint(Canvas canvas, Size size) {
    const top = -32.0, bottom = -100.0;
    const padL = 36.0, padR = 36.0, padT = 8.0, padB = 16.0;
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

    // 纵轴：-100 到 -30，每 10dBm 一格（更通用）
    for (var v = -30; v >= bottom; v -= 10) {
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
    // 横轴
    canvas.drawLine(Offset(padL, padT), Offset(padL, size.height - padB),
        axisPaint);
    canvas.drawLine(Offset(padL, size.height - padB),
        Offset(size.width - padR, size.height - padB), axisPaint);

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

    // 数据点（最多取最近 120 个），x 均分；超出纵轴范围按边界绘制
    final pts = values.length > 120
        ? values.sublist(values.length - 120)
        : values;
    final n = pts.length;
    final path = Path();
    for (var i = 0; i < n; i++) {
      final x = n == 1 ? padL + chartW : padL + chartW * i / (n - 1);
      final v = pts[i].clamp(bottom.toInt(), top.toInt()).toDouble();
      final y = padT + (top - v) / (top - bottom) * chartH;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _RssiPainter old) => old.values != values;
}
