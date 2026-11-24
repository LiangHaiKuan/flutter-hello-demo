import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/ble_engine.dart';
import 'device_page.dart';

/// 扫描主页：可用设备 / 活动连接
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final BleEngine _engine = BleEngine.instance;
  Timer? _loopTimer;

  @override
  void initState() {
    super.initState();
    _engine.bindScanStreams();
    _engine.loadCmds();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScan());
  }

  @override
  void dispose() {
    _loopTimer?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    await _ensurePermissions();
    _engine.startScan();
  }

  Future<void> _ensurePermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  void _scheduleLoop() {
    _loopTimer?.cancel();
    if (_engine.loopScan) {
      _loopTimer =
          Timer.periodic(Duration(seconds: _engine.scanPeriodSec), (_) {
        if (!_engine.scanning.value) _engine.startScan();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('BLE调试助手'),
          actions: [
            ValueListenableBuilder<bool>(
              valueListenable: _engine.scanning,
              builder: (_, s, __) => IconButton(
                icon: Icon(s ? Icons.pause_circle_outline : Icons.refresh),
                tooltip: s ? '停止扫描' : '开始扫描',
                onPressed: () async {
                  if (s) {
                    _engine.stopScan();
                  } else {
                    await _startScan();
                    _scheduleLoop();
                  }
                },
              ),
            ),
            IconButton(
              icon: const Icon(Icons.filter_list),
              tooltip: '扫描过滤',
              onPressed: () => Scaffold.of(context).openEndDrawer(),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'settings') _showScanSettings();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'settings', child: Text('扫描设置')),
              ],
            ),
          ],
          bottom: const TabBar(
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [Tab(text: '可用设备'), Tab(text: '活动连接')],
          ),
        ),
        endDrawer: const _FilterDrawer(),
        body: TabBarView(
          children: [_AvailableTab(onLoopChanged: _scheduleLoop), _ActiveTab()],
        ),
      ),
    );
  }

  void _showScanSettings() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('扫描设置',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('单次扫描周期'),
                  const Spacer(),
                  DropdownButton<int>(
                    value: _engine.scanPeriodSec,
                    items: const [5, 10, 15, 30, 60]
                        .map((v) => DropdownMenuItem(
                            value: v, child: Text('$v 秒')))
                        .toList(),
                    onChanged: (v) => setSheet(
                        () => _engine.scanPeriodSec = v ?? 10),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('循环扫描'),
                subtitle: const Text('每轮扫描结束后自动重新开始'),
                value: _engine.loopScan,
                onChanged: (v) {
                  setSheet(() => _engine.loopScan = v);
                  _scheduleLoop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- Tab1 可用设备 ----------------
class _AvailableTab extends StatelessWidget {
  final VoidCallback onLoopChanged;
  const _AvailableTab({required this.onLoopChanged});

  @override
  Widget build(BuildContext context) {
    final engine = BleEngine.instance;
    return ValueListenableBuilder<List<ScanResult>>(
      valueListenable: engine.scanResults,
      builder: (_, results, __) {
        if (results.isEmpty) {
          return const Center(
            child: Text('未发现设备，请确认设备已打开广播',
                style: TextStyle(color: Colors.grey)),
          );
        }
        return ListView.separated(
          itemCount: results.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, indent: 16, endIndent: 16),
          itemBuilder: (_, i) {
            final r = results[i];
            return _DeviceCard(result: r);
          },
        );
      },
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final ScanResult result;
  const _DeviceCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final engine = BleEngine.instance;
    final dev = result.device;
    final mac = dev.remoteId.str;
    final name =
        result.advertisementData.advName.isNotEmpty
            ? result.advertisementData.advName
            : '未知设备';
    final connectable = result.advertisementData.connectable;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFFF57C00),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bluetooth, color: Colors.white, size: 20),
                  Text('BLE',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(mac,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 2),
                  Text(
                    connectable ? '未配对    可连接' : '仅广播',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            Text('${result.rssi} dBm',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(width: 12),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF57C00),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              ),
              onPressed: () async {
                await engine.connect(dev);
                if (!context.mounted) return;
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DevicePage(mac: mac, name: name),
                ));
              },
              child: const Text('连接'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- Tab2 活动连接 ----------------
class _ActiveTab extends StatelessWidget {
  final BleEngine _engine = BleEngine.instance;

  _ActiveTab();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _engine.sessionsBump,
      builder: (_, __, ___) {
        final sessions = _engine.sessionList;
        if (sessions.isEmpty) {
          return const Center(
            child: Text('暂无活动连接', style: TextStyle(color: Colors.grey)),
          );
        }
        return ListView.separated(
          itemCount: sessions.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, indent: 16, endIndent: 16),
          itemBuilder: (_, i) {
            final s = sessions[i];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.green.withAlpha(40),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.link, color: Colors.green),
                ),
                title: Text(s.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(s.mac),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: s.rssi,
                      builder: (_, r, __) => r > 0
                          ? Text('$r dBm',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey))
                          : const SizedBox.shrink(),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => s.disconnect(),
                      child: const Text('断开',
                          style: TextStyle(color: Colors.redAccent)),
                    ),
                  ],
                ),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      DevicePage(mac: s.mac, name: s.name),
                )),
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------- 过滤抽屉 ----------------
class _FilterDrawer extends StatefulWidget {
  const _FilterDrawer();

  @override
  State<_FilterDrawer> createState() => _FilterDrawerState();
}

class _FilterDrawerState extends State<_FilterDrawer> {
  final BleEngine _engine = BleEngine.instance;
  late final TextEditingController _nameCtl;
  late final TextEditingController _uuidCtl;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: _engine.nameFilter);
    _uuidCtl = TextEditingController(text: _engine.uuidFilter);
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFFF2F2F2),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _nameCtl,
              decoration: const InputDecoration(hintText: '根据名称或地址过滤'),
              onChanged: (v) => _engine.nameFilter = v,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _uuidCtl,
              decoration: const InputDecoration(hintText: '0x 根据uuid过滤'),
              onChanged: (v) => _engine.uuidFilter = v,
            ),
            const SizedBox(height: 8),
            _checkTile('只显示BLE设备', _engine.onlyBle,
                (v) => _engine.onlyBle = v ?? true),
            // 收藏功能二期实现
            _checkTile('只显示名称不为空的', _engine.onlyNamed,
                (v) => _engine.onlyNamed = v ?? false),
            Row(
              children: [
                const Text('RSSI'),
                Expanded(
                  child: Slider(
                    activeColor: const Color(0xFFF57C00),
                    min: -100,
                    max: 0,
                    divisions: 100,
                    value: _engine.rssiThreshold.toDouble(),
                    onChanged: (v) {
                      setState(() => _engine.rssiThreshold = v.round());
                    },
                  ),
                ),
                Text('${_engine.rssiThreshold}'),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF57C00),
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  Navigator.of(context).pop();
                  // 触发一次过滤重算
                  BleEngine.instance.startScan();
                },
                child: const Text('应用过滤并重新扫描'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _checkTile(String label, bool value, ValueChanged<bool?> onChanged) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      value: value,
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: const Color(0xFFF57C00),
      onChanged: (v) {
        setState(() => onChanged(v));
      },
    );
  }
}
