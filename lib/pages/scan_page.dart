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
  bool _showFilter = true; // 过滤面板默认显示（对标原版）

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
              icon: Icon(
                  _showFilter ? Icons.filter_alt : Icons.filter_alt_outlined,
                  color: _showFilter ? Colors.white : Colors.white70),
              tooltip: '显示/隐藏过滤面板',
              onPressed: () => setState(() => _showFilter = !_showFilter),
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
        body: Column(
          children: [
            if (_showFilter) _FilterPanel(),
            Expanded(
              child: TabBarView(
                children: [
                  _AvailableTab(onLoopChanged: _scheduleLoop),
                  _ActiveTab(),
                ],
              ),
            ),
          ],
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

// ---------------- 过滤面板（常驻顶部，对标原版布局） ----------------
class _FilterPanel extends StatefulWidget {
  @override
  State<_FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<_FilterPanel> {
  final BleEngine _engine = BleEngine.instance;
  late final TextEditingController _nameCtl;
  late final TextEditingController _uuidCtl;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: _engine.nameFilter);
    _uuidCtl = TextEditingController(text: _engine.uuidFilter);
  }

  void _apply() => _engine.notifyFilters();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF2F2F2),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        children: [
          TextField(
            controller: _nameCtl,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '根据名称或地址过滤',
            ),
            onChanged: (v) {
              _engine.nameFilter = v;
              _apply();
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _uuidCtl,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '0x 根据uuid过滤',
            ),
            onChanged: (v) {
              _engine.uuidFilter = v;
              _apply();
            },
          ),
          _checkRow('只显示BLE设备', _engine.onlyBle, (v) {
            _engine.onlyBle = v;
            _apply();
          }),
          _checkRow('只显示名称不为空的', _engine.onlyNamed, (v) {
            _engine.onlyNamed = v;
            _apply();
          }),
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
                  onChanged: (v) =>
                      setState(() => _engine.rssiThreshold = v.round()),
                  onChangeEnd: (_) => _apply(),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text('${_engine.rssiThreshold}',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _checkRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Checkbox(
          value: value,
          onChanged: (v) {
            setState(() => onChanged(v ?? false));
          },
        ),
        Text(label, style: const TextStyle(fontSize: 14)),
      ],
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

  @override
  Widget build(BuildContext context) {
    final engine = BleEngine.instance;
    final dev = result.device;
    final mac = dev.remoteId.str;
    final name =
        result.advertisementData.advName.isNotEmpty
            ? result.advertisementData.advName
            : '未知设备';

    // 连接状态（对标原版：未连接灰色，连上才能操作）
    final session = engine.sessions[mac];
    final isConnected = session != null &&
        session.state.value == BluetoothConnectionState.connected;
    final isConnecting = session != null && !isConnected;

    final iconColor = isConnected ? const Color(0xFFF57C00) : Colors.grey;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // 点图标 → 广播数据页（对标原版广播数据入口）
            GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AdvDataPage(mac: mac, name: name),
              )),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withAlpha(isConnected ? 40 : 30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.bluetooth, color: iconColor, size: 20),
                    Text('BLE',
                        style: TextStyle(
                            color: iconColor,
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
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: isConnected
                                ? Colors.black87
                                : Colors.black38)),
                    const SizedBox(height: 2),
                    Text(mac,
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 2),
                    Text(
                      isConnected
                          ? '已连接'
                          : (isConnecting ? '连接中...' : '未连接'),
                      style: TextStyle(
                          fontSize: 12,
                          color: isConnected
                              ? Colors.green
                              : Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
            Text('${result.rssi} dBm',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(width: 12),
            // 广播数据小图标
            IconButton(
              icon: const Icon(Icons.bar_chart, size: 20, color: Colors.grey),
              tooltip: '广播数据',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AdvDataPage(mac: mac, name: name),
              )),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isConnected
                    ? Colors.green
                    : (isConnecting
                        ? Colors.grey
                        : const Color(0xFFF57C00)),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              ),
              onPressed: isConnecting
                  ? null
                  : () async {
                      if (isConnected) {
                        // 已连接：直接进入设备页
                        if (!context.mounted) return;
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => DevicePage(mac: mac, name: name),
                        ));
                      } else {
                        // 发起连接并立即进入设备页（页内显示"连接中"）
                        engine.connect(dev);
                        if (!context.mounted) return;
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => DevicePage(mac: mac, name: name),
                        ));
                      }
                    },
              child: Text(isConnected
                  ? '进入'
                  : (isConnecting ? '连接中' : '连接')),
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
              child: ValueListenableBuilder<BluetoothConnectionState>(
                valueListenable: s.state,
                builder: (_, st, ___) {
                  final connected =
                      st == BluetoothConnectionState.connected;
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
                          connected ? Icons.link : Icons.link_off,
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
                        '${s.mac}  ·  ${connected ? "已连接" : "未连接/断开"}',
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
