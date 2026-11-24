import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ble_util.dart';
import '../models/models.dart';

/// 每台已连接设备的会话状态
class DeviceSession {
  final BluetoothDevice device;
  final ValueNotifier<BluetoothConnectionState> state =
      ValueNotifier(BluetoothConnectionState.disconnected);
  final ValueNotifier<int> rssi = ValueNotifier(0);
  final ValueNotifier<bool> servicesReady = ValueNotifier(false);

  /// 服务树（发现服务后填充）
  List<BluetoothService> services = [];

  /// 当前发送目标特征
  final ValueNotifier<BluetoothCharacteristic?> targetChar =
      ValueNotifier(null);

  /// 通知开启状态记录 charUuidStr -> bool
  final Map<String, bool> notifyState = {};

  /// 发送历史（最新在前）
  final ValueNotifier<List<String>> writeHistory = ValueNotifier([]);

  /// 收发统计
  int recvPkts = 0, recvBytes = 0;
  int sentOkPkts = 0, sentOkBytes = 0;
  int sentFailPkts = 0, sentFailBytes = 0;
  final ValueNotifier<int> statsBump = ValueNotifier(0); // 触发界面刷新

  StreamSubscription? _connSub;
  Timer? _rssiTimer;
  final Map<String, StreamSubscription> _notifySubs = {};

  DeviceSession(this.device) {
    _connSub = device.connectionState.listen(_onConnState);
  }

  String get mac => device.remoteId.str;
  String get name => device.platformName.isNotEmpty ? device.platformName : '未知设备';

  Future<void> init() async {
    await device.connect(timeout: const Duration(seconds: 15), autoConnect: false);
  }

  void _onConnState(BluetoothConnectionState s) {
    state.value = s;
    if (s == BluetoothConnectionState.connected) {
      _afterConnected();
    } else if (s == BluetoothConnectionState.disconnected) {
      _onDisconnected();
    }
  }

  Future<void> _afterConnected() async {
    BleEngine.instance.logEvent(mac, '连接成功，等待发现服务');
    try {
      services = await device.discoverServices();
      servicesReady.value = true;
      BleEngine.instance.logEvent(mac, '连接成功，并成功发现服务');
      // 默认发送目标：第一个可写特征
      targetChar.value ??= _firstWritable();
      // RSSI 定时刷新
      _rssiTimer?.cancel();
      _rssiTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        try {
          rssi.value = (await device.readRssi()).round();
        } catch (_) {}
      });
    } catch (e) {
      BleEngine.instance.logEvent(mac, '发现服务失败: $e');
    }
  }

  BluetoothCharacteristic? _firstWritable() {
    for (final s in services) {
      for (final c in s.characteristics) {
        if (c.properties.write || c.properties.writeWithoutResponse) {
          return c;
        }
      }
    }
    return null;
  }

  void _onDisconnected() {
    _rssiTimer?.cancel();
    for (final sub in _notifySubs.values) {
      sub.cancel();
    }
    _notifySubs.clear();
    BleEngine.instance.logEvent(mac, '连接已断开');
    BleEngine.instance.removeSession(this);
  }

  Future<void> disconnect() async {
    await device.disconnect();
  }

  /// 开关通知
  Future<bool> setNotify(BluetoothCharacteristic c, bool enable) async {
    try {
      await c.setNotifyValue(enable);
      notifyState[c.uuid.str.toLowerCase()] = enable;
      if (enable && !_notifySubs.containsKey(c.uuid.str)) {
        _notifySubs[c.uuid.str] = c.onValueReceived.listen((v) {
          recvPkts++;
          recvBytes += v.length;
          statsBump.value++;
          final isInd = c.properties.indicate && !c.properties.notify;
          BleEngine.instance.addDataLog(
            mac,
            c.uuid.str.toLowerCase(),
            isInd ? LogDir.indicate : LogDir.notify,
            v,
          );
        });
      }
      BleEngine.instance.logEvent(
          mac, '[${shortUuid(c.uuid.str)}] Notification${enable ? '开启' : '关闭'}');
      return true;
    } catch (e) {
      BleEngine.instance.logEvent(mac, '设置通知失败: $e');
      return false;
    }
  }

  /// 读特征值
  Future<void> readChar(BluetoothCharacteristic c) async {
    try {
      final v = await c.read();
      recvPkts++;
      recvBytes += v.length;
      statsBump.value++;
      BleEngine.instance.addDataLog(mac, c.uuid.str.toLowerCase(), LogDir.read, v);
    } catch (e) {
      BleEngine.instance.logEvent(mac, '读取失败: $e');
    }
  }

  /// 发送数据到目标特征。返回是否成功。
  Future<bool> send(List<int> bytes, bool withoutResponse,
      {BluetoothCharacteristic? to, bool recordHistory = true}) async {
    final c = to ?? targetChar.value;
    if (c == null) return false;
    try {
      await c.write(bytes, withoutResponse: withoutResponse);
      sentOkPkts++;
      sentOkBytes += bytes.length;
      statsBump.value++;
      BleEngine.instance.addDataLog(
          mac, c.uuid.str.toLowerCase(), LogDir.sendOk, bytes);
      if (recordHistory) {
        final h = List<String>.from(writeHistory.value);
        h.insert(0, HexUtil.toHex(bytes));
        if (h.length > 50) h.removeLast();
        writeHistory.value = h;
      }
      return true;
    } catch (e) {
      sentFailPkts++;
      statsBump.value++;
      BleEngine.instance.logEvent(mac, '发送失败: $e');
      return false;
    }
  }

  void dispose() {
    _rssiTimer?.cancel();
    _connSub?.cancel();
    for (final sub in _notifySubs.values) {
      sub.cancel();
    }
    state.dispose();
    rssi.dispose();
    servicesReady.dispose();
    targetChar.dispose();
    writeHistory.dispose();
    statsBump.dispose();
  }
}

/// 全局 BLE 引擎
class BleEngine {
  BleEngine._();
  static final BleEngine instance = BleEngine._();

  final ValueNotifier<bool> scanning = ValueNotifier(false);
  final ValueNotifier<List<ScanResult>> scanResults = ValueNotifier([]);

  /// 会话，key = mac
  final Map<String, DeviceSession> sessions = {};
  final ValueNotifier<int> sessionsBump = ValueNotifier(0);

  /// 全量日志（跨设备都带 mac，页面自行过滤）
  final ValueNotifier<List<LogEntry>> logs = ValueNotifier([]);
  static const int _maxLogs = 5000;

  /// 扫描过滤条件
  String nameFilter = '';
  String uuidFilter = '';
  bool onlyBle = true;
  bool onlyNamed = false;
  int rssiThreshold = -100;

  bool loopScan = false;
  int scanPeriodSec = 10;

  // ---- 自定义按键持久化 ----
  List<FastCmd> cmds = [];
  final ValueNotifier<int> cmdsBump = ValueNotifier(0);

  Future<void> loadCmds() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('fast_cmds');
    if (raw == null || raw.isEmpty) return;
    try {
      final arr = jsonDecode(raw) as List;
      cmds = arr
          .whereType<Map>()
          .map((e) => FastCmd.fromJson(e.cast<String, dynamic>()))
          .toList()
        ..sort((a, b) => a.order.compareTo(b.order));
      cmdsBump.value++;
    } catch (_) {
      cmds = [];
    }
  }

  Future<void> saveCmds() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
        'fast_cmds', jsonEncode(cmds.map((c) => c.toJson()).toList()));
  }

  // ---- 扫描 ----
  Future<void> startScan({int? timeoutSec}) async {
    await FlutterBluePlus.stopScan();
    scanResults.value = [];
    final t = timeoutSec ?? scanPeriodSec;
    await FlutterBluePlus.startScan(
      timeout: Duration(seconds: t),
      continuousUpdates: true,
      continuousDivisor: 3,
    );
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  void bindScanStreams() {
    FlutterBluePlus.isScanning.listen((s) => scanning.value = s);
    FlutterBluePlus.scanResults.listen((results) {
      scanResults.value = _filterResults(results);
    });
  }

  List<ScanResult> _filterResults(List<ScanResult> input) {
    final map = <String, ScanResult>{};
    for (final r in input) {
      final mac = r.device.remoteId.str;
      final adv = r.advertisementData;
      final advName = adv.advName;

      // 名称/地址过滤（不分大小写）
      final kw = nameFilter.trim().toLowerCase();
      if (kw.isNotEmpty &&
          !advName.toLowerCase().contains(kw) &&
          !mac.toLowerCase().contains(kw)) {
        continue;
      }
      // UUID 过滤
      final uf = uuidFilter.trim().toLowerCase();
      if (uf.isNotEmpty) {
        final allUuids = [
          ...adv.serviceUuids.map((g) => g.str.toLowerCase()),
          ...adv.serviceData.keys.map((g) => g.str.toLowerCase()),
        ];
        if (!allUuids.any((u) => u.contains(uf.replaceAll('0x', '')))) {
          continue;
        }
      }
      if (onlyNamed && advName.isEmpty) continue;
      if (r.rssi < rssiThreshold) continue;
      // BLE-only：fbp 只返回 BLE 广播，该项仅影响 connectable 过滤
      if (onlyBle && !adv.connectable) continue;

      map[mac] = r; // 去重，保留最新
    }
    final list = map.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  // ---- 连接 ----
  DeviceSession? sessionOf(String mac) => sessions[mac];

  Future<void> connect(BluetoothDevice device) async {
    final mac = device.remoteId.str;
    if (sessions.containsKey(mac)) return;
    final s = DeviceSession(device);
    sessions[mac] = s;
    sessionsBump.value++;
    try {
      await s.init();
    } catch (e) {
      logEvent(mac, '连接失败: $e');
      removeSession(s);
    }
  }

  void removeSession(DeviceSession s) {
    if (sessions.remove(s.mac) != null) {
      sessionsBump.value++;
    }
    s.dispose();
  }

  List<DeviceSession> get sessionList => sessions.values.toList();

  // ---- 日志 ----
  void addDataLog(String mac, String uuid, LogDir dir, List<int> bytes) {
    _append(LogEntry(
      time: DateTime.now(),
      dir: dir,
      tag: shortUuid(uuid),
      bytes: bytes,
    ));
  }

  void logEvent(String mac, String msg) {
    _append(LogEntry(
      time: DateTime.now(),
      dir: LogDir.event,
      tag: '',
      message: msg,
    ));
  }

  void _append(LogEntry e) {
    final list = List<LogEntry>.from(logs.value);
    list.add(e);
    if (list.length > _maxLogs) {
      list.removeRange(0, list.length - _maxLogs);
    }
    logs.value = list;
  }

  void clearLogs() {
    logs.value = [];
  }
}

/// UUID 缩写：取后 4 位，如 ffe1
String shortUuid(String uuid) {
  final u = uuid.toLowerCase().replaceAll('-', '');
  return u.length >= 4 ? u.substring(u.length - 4) : u;
}
