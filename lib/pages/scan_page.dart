import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/ble_engine.dart';
import 'adv_data_page.dart';
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
    _engine.loadSettings();
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
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'scan') _showScanSettings();
                if (v == 'filter') _showFilterSettings();
                if (v == 'conn') _showConnectSettings();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'scan', child: Text('扫描设置')),
                PopupMenuItem(value: 'filter', child: Text('过滤设置')),
                PopupMenuItem(value: 'conn', child: Text('连接设置')),
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
        body: TabBarView(
          children: [
            _AvailableTab(onLoopChanged: _scheduleLoop),
            _ActiveTab(),
          ],
        ),
      ),
    );
  }

  // ---------- 扫描设置 ----------
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

  // ---------- 过滤设置（与扫描设置同等角色，弹窗形式） ----------
  void _showFilterSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('过滤设置',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _engine.notifyFilters();
                    },
                    child: const Text('完成'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller:
                    TextEditingController(text: _engine.nameFilter),
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '根据名称或地址过滤',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  _engine.nameFilter = v;
                  _engine.notifyFilters();
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller:
                    TextEditingController(text: _engine.uuidFilter),
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '0x 根据uuid过滤',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  _engine.uuidFilter = v;
                  _engine.notifyFilters();
                },
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('只显示BLE设备'),
                value: _engine.onlyBle,
                activeColor: const Color(0xFFF57C00),
                onChanged: (v) {
                  setSheet(() => _engine.onlyBle = v ?? false);
                  _engine.notifyFilters();
                },
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('只显示名称不为空的'),
                value: _engine.onlyNamed,
                activeColor: const Color(0xFFF57C00),
                onChanged: (v) {
                  setSheet(() => _engine.onlyNamed = v ?? false);
                  _engine.notifyFilters();
                },
              ),
              Row(
                children: [
                  const Text('RSSI', style: TextStyle(fontSize: 14)),
                  Expanded(
                    child: Slider(
                      activeColor: const Color(0xFFF57C00),
                      min: -100,
                      max: 0,
                      divisions: 100,
                      value: _engine.rssiThreshold.toDouble(),
                      onChanged: (v) => setSheet(
                          () => _engine.rssiThreshold = v.round()),
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text('${_engine.rssiThreshold}',
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 连接设置 ----------
  void _showConnectSettings() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('连接设置',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('断线自动回连'),
                subtitle: const Text('设备断电又重新上电后，自动尝试重新连接（每 5 秒一次，直到连上或手动断开）'),
                value: _engine.autoReconnect,
                activeColor: const Color(0xFFF57C00),
                onChanged: (v) async {
                  await _engine.setAutoReconnect(v);
                  setSheet(() {});
                },
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '提示：关闭后，已断开的设备需要你在列表里手动点「回连」。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- Tab1 可用设备 ----------------
class _AvailableTab extends StatefulWidget {
  final VoidCallback onLoopChanged;
  const _AvailableTab({required this.onLoopChanged});

  @override
  State<_AvailableTab> createState() => _AvailableTabState();
}

class _AvailableTabState extends State<_AvailableTab> {
  final BleEngine _engine = BleEngine.instance;
  Timer? _sortTimer;

  @override
  void initState() {
    super.initState();
    // 每 3 秒强制刷新一次，保证按信号强度重新排列（对标原版）
    _sortTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sortTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<ScanResult>>(
      valueListenable: _engine.scanResults,
      builder: (_, results, __) {
        return ValueListenableBuilder<int>(
          valueListenable: _engine.filterBump,
          builder: (_, ___, ____) {
            final filtered = _engine.applyFilters(results);
            if (filtered.isEmpty) {
              return const Center(
                child: Text('未发现设备，请确认设备已打开广播',
                    style: TextStyle(color: Colors.grey)),
              );
            }
            return ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (_, i) {
                final r = filtered[i];
                return _DeviceCard(result: r);
              },
            );
          },
        );
      },
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final ScanResult result;
  const _DeviceCard({required this.result});

  void _openDevicePage(BuildContext context, String mac, String name) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DevicePage(mac: mac, name: name),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final engine = BleEngine.instance;
    final dev = result.device;
    final mac = dev.remoteId.str;
    final name = result.advertisementData.advName.isNotEmpty
        ? result.advertisementData.advName
        : '未知设备';

    final session = engine.sessions[mac];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // 点图标 → 广播数据页
            GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AdvDataPage(mac: mac, name: name),
              )),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFF57C00).withAlpha(35),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.bluetooth,
                        color: Color(0xFFF57C00), size: 20),
                    Text('BLE',
                        style: TextStyle(
                            color: Colors.orange.shade700,
                            fontSize: 8,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => AdvDataPage(mac: mac, name: name),
                )),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87)),
                    const SizedBox(height: 2),
                    Text(mac,
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
            ),
            Text('${result.rssi} dBm',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.bar_chart, size: 20, color: Colors.grey),
              tooltip: '广播数据',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AdvDataPage(mac: mac, name: name),
              )),
            ),
            // 连接/进入/回连按钮（实时反映连接状态）
            _connectButton(context, engine, session, dev, mac, name),
          ],
        ),
      ),
    );
  }

  Widget _connectButton(
      BuildContext context,
      BleEngine engine,
      DeviceSession? session,
      BluetoothDevice dev,
      String mac,
      String name) {
    if (session == null) {
      return ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFF57C00),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        ),
        onPressed: () {
          engine.connect(dev);
          _openDevicePage(context, mac, name);
        },
        child: const Text('连接'),
      );
    }
    return ValueListenableBuilder<BluetoothConnectionState>(
      valueListenable: session.state,
      builder: (_, st, __) {
        final connected = st == BluetoothConnectionState.connected;
        final connecting = st == BluetoothConnectionState.connecting;
        return ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: connected
                ? Colors.green
                : (connecting ? Colors.grey : const Color(0xFFF57C00)),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          ),
          onPressed: connecting
              ? null
              : () {
                  if (!connected) engine.connect(dev);
                  _openDevicePage(context, mac, name);
                },
          child: Text(connected ? '进入' : (connecting ? '连接中' : '回连')),
        );
      },
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
              child: ValueListenableBuilder<BluetoothConnectionState>(
                valueListenable: s.state,
                builder: (_, st, ___) {
                  final connected = st == BluetoothConnectionState.connected;
                  final connecting = st == BluetoothConnectionState.connecting;
                  final color = connected ? Colors.green : Colors.grey;
                  return ListTile(
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: color.withAlpha(40),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                          connected
                              ? Icons.link
                              : Icons.link_off,
                          color: color),
                    ),
                    title: Text(
                      s.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: connected
                            ? Colors.black87
                            : Colors.black38, // 断开变灰
                      ),
                    ),
                    subtitle: Text(
                        '${s.mac}  ·  ${connected ? "已连接" : (connecting ? "连接中" : "已断开")}',
                        style: TextStyle(
                            fontSize: 12,
                            color: connected
                                ? Colors.grey
                                : Colors.grey.shade400)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ValueListenableBuilder<int>(
                          valueListenable: s.rssi,
                          builder: (_, r, __) => connected && r > 0
                              ? Text('$r dBm',
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.grey))
                              : const SizedBox.shrink(),
                        ),
                        const SizedBox(width: 8),
                        // 断开 / 回连 按钮原地切换（不跳转）
                        TextButton(
                          onPressed: connecting
                              ? null
                              : () async {
                                  if (connected) {
                                    await s.disconnect();
                                  } else {
                                    await BleEngine.instance.connect(s.device);
                                  }
                                },
                          child: Text(
                            connected ? '断开' : '回连',
                            style: TextStyle(
                                color: connected
                                    ? Colors.redAccent
                                    : const Color(0xFFF57C00)),
                          ),
                        ),
                      ],
                    ),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => DevicePage(mac: s.mac, name: s.name),
                    )),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}
