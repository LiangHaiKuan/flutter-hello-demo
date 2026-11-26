import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/ble_engine.dart';
import '../core/version.dart';
import '../widgets/log_floating.dart';
import 'adv_data_page.dart';
import 'device_page.dart';
import 'peripheral_page.dart';

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
                if (v == 'peripheral') _openPeripheralMode();
                if (v == 'autofeat') _showAutoFeatureSettings();
                if (v == 'log') FloatingLog.instance.toggle(context);
                if (v == 'changelog') _showChangelog();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'scan', child: Text('扫描设置')),
                PopupMenuItem(value: 'filter', child: Text('过滤设置')),
                PopupMenuItem(value: 'conn', child: Text('连接设置')),
                PopupMenuItem(value: 'autofeat', child: Text('自动特征')),
                PopupMenuItem(value: 'peripheral', child: Text('外围模式')),
                PopupMenuItem(value: 'log', child: Text('悬浮日志')),
                PopupMenuItem(value: 'changelog', child: Text('更新内容 (v1.9)')),
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

  // ---------- 外围模式（手机当 BLE 从机） ----------
  void _openPeripheralMode() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const PeripheralConfigPage(),
    ));
  }

  // ---------- 更新内容（v1.6 起：三点菜单里可查版本号与每版改动） ----------
  void _showChangelog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('BLE调试助手 $appVersion'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final v in appChangelog) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 4),
                  child: Text(
                    '${v['version']}（${v['date']}）'
                    '${v['version'] == appVersion ? '  ← 当前版本' : ''}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF57C00)),
                  ),
                ),
                for (final item in (v['items'] as List<dynamic>))
                  Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 2),
                    child: Text('· $item',
                        style: const TextStyle(fontSize: 13)),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  // ---------- 自动特征：连接后自动点亮发送目标 + 开通知 + 跳实时日志 ----------
  Future<void> _showAutoFeatureSettings() async {
    final e = _engine;
    final svcCtl = TextEditingController(text: e.autoFeatServiceUuid);
    final writeCtl = TextEditingController(text: e.autoFeatWriteUuid);
    final notifyCtl = TextEditingController(text: e.autoFeatNotifyUuid);
    await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('自动特征'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    '连接后若服务/特征 UUID 匹配，自动点亮发送目标、开启通知，'
                    '并直接跳到实时日志页操作。',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用自动特征'),
                  value: e.autoFeatureEnabled,
                  activeColor: const Color(0xFFF57C00),
                  onChanged: (v) => setD(() => e.autoFeatureEnabled = v),
                ),
                TextField(
                  controller: svcCtl,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: '服务 UUID（完整）',
                    hintText: '0000ffe0-0000-1000-8000-00805f9b34fb',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => e.autoFeatServiceUuid = v.trim(),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: writeCtl,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: '发送目标特征 UUID（完整）',
                    hintText: '0000ffe1-0000-1000-8000-00805f9b34fb',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => e.autoFeatWriteUuid = v.trim(),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: notifyCtl,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: '通知特征 UUID（完整）',
                    hintText: '0000ffe2-0000-1000-8000-00805f9b34fb',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => e.autoFeatNotifyUuid = v.trim(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            ElevatedButton(
              onPressed: () {
                e.saveAutoFeature();
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
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
      // SafeArea：适配手势导航条，避免底部控件被系统栏压住
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
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
                      max: -20, // 信号强度范围 -20 ~ -100
                      divisions: 80,
                      value: _engine.rssiThreshold
                          .clamp(-100, -20)
                          .toDouble(),
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
            return ValueListenableBuilder<int>(
              valueListenable: _engine.sessionsBump,
              builder: (_, ____, _____) {
                final filtered = _engine.applyFilters(results);
                // 活动连接的设备置顶显示（它们可能不在广播列表里），按钮为"查看"
                final seen = filtered.map((r) => r.device.remoteId.str).toSet();
                final pinned = _engine.sessionList
                    .where((s) => !seen.contains(s.mac))
                    .toList();
                if (filtered.isEmpty && pinned.isEmpty) {
                  return const Center(
                    child: Text('未发现设备，请确认设备已打开广播',
                        style: TextStyle(color: Colors.grey)),
                  );
                }
                // 下拉刷新：重新开始扫描
                return RefreshIndicator(
                  color: const Color(0xFFF57C00),
                  onRefresh: () => _engine.startScan(),
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: pinned.length + filtered.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 16, endIndent: 16),
                    itemBuilder: (_, i) {
                      if (i < pinned.length) {
                        final s = pinned[i];
                        return _PinnedSessionCard(session: s);
                      }
                      final r = filtered[i - pinned.length];
                      return _DeviceCard(result: r);
                    },
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// 活动连接置顶卡：显示"查看"按钮，点进去直接操作
class _PinnedSessionCard extends StatelessWidget {
  final DeviceSession session;
  const _PinnedSessionCard({required this.session});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 1,
      color: const Color(0xFFFFF6EE),
      child: ValueListenableBuilder<BluetoothConnectionState>(
        valueListenable: session.state,
        builder: (_, st, ___) {
          final connected = st == BluetoothConnectionState.connected;
          final connecting = st == BluetoothConnectionState.connecting;
          return ListTile(
            leading: Icon(
              connected ? Icons.link : Icons.link_off,
              color: connected ? Colors.green : Colors.grey,
            ),
            title: Text(session.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${session.mac} · ${connected ? "已连接" : (connecting ? "连接中" : "已断开")}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            trailing: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF57C00),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              ),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DevicePage(mac: session.mac, name: session.name),
              )),
              child: const Text('查看'),
            ),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DevicePage(mac: session.mac, name: session.name),
            )),
          );
        },
      ),
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

    // 卡片结构（v1.5 重排）：第一行 = 完整设备名独占一行；
    // 第二行 = MAC · 信号强度 · 广播数据按钮 · 连接按钮。
    // 原 44x44 "BLE" 方块图标仅装饰（广播数据另有柱状图入口），已去掉，把空间留给名称。
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第一行：完整设备名（太长自动省略号）
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87)),
            const SizedBox(height: 4),
            // 第二行（v1.8）：MAC / 信号强度 / 广播包 均匀分列，连接按钮靠右
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(mac,
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                Expanded(
                  flex: 2,
                  child: Text('${result.rssi} dBm',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                Expanded(
                  flex: 2,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      alignment: Alignment.centerLeft,
                    ),
                    child: const Text('广播包',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => AdvDataPage(mac: mac, name: name))),
                  ),
                ),
                _connectButton(context, engine, session, dev, mac, name),
              ],
            ),
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
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
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
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
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
                                ? Colors.grey.shade400 // v1.5 变浅，降低对比度
                                : Colors.grey.shade300)),
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
                        // v1.6：销毁按钮——断开并移除会话，活动连接列表里直接消失
                        if (connected)
                          TextButton(
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('销毁该设备'),
                                  content: const Text(
                                      '将断开连接并从「活动连接」列表中移除（回连需重新扫描）。确定？'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text('取消')),
                                    ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.redAccent,
                                            foregroundColor: Colors.white),
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text('销毁')),
                                  ],
                                ),
                              );
                              if (ok != true) return;
                              await s.disconnect();
                              BleEngine.instance.removeSession(s);
                            },
                            child: const Text('销毁',
                                style: TextStyle(color: Colors.redAccent)),
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
