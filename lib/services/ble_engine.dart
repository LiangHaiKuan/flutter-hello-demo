import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ble_util.dart';
import '../models/models.dart';

/// 每台设备的会话状态
///
/// v1.2 起：断开后会话【保留】，界面变灰并可一键回连；
/// 只有 app 退出才清理。连接失败也不再移除会话（修复第一次连接失败进不去页面的问题）。
class DeviceSession {
  final BluetoothDevice device;
  final ValueNotifier<BluetoothConnectionState> state =
      ValueNotifier(BluetoothConnectionState.disconnected);
  final ValueNotifier<int> rssi = ValueNotifier(0);
  final ValueNotifier<bool> servicesReady = ValueNotifier(false);

  /// 服务树（发现服务后填充）
  List<BluetoothService> services = [];

  /// 用户展开的服务（记忆展开状态：返回本页时保持）
  final Set<String> expandedServices = {};

  /// 当前发送目标特征
  final ValueNotifier<BluetoothCharacteristic?> targetChar =
      ValueNotifier(null);

  /// 通知开启状态记录 charUuidStr -> bool
  final Map<String, bool> notifyState = {};

  /// 通知状态变化计数（铃铛图标即时点亮/熄灭用）
  final ValueNotifier<int> notifyBump = ValueNotifier(0);

  /// 发送历史（最新在前）
  final ValueNotifier<List<String>> writeHistory = ValueNotifier([]);

  /// 收发统计
  int recvPkts = 0, recvBytes = 0;
  int sentOkPkts = 0, sentOkBytes = 0;
  int sentFailPkts = 0, sentFailBytes = 0;
  final ValueNotifier<int> statsBump = ValueNotifier(0);

  /// 当前 MTU（连接成功后请求 512）
  int mtu = 0;

  /// 用户手动断开（不触发自动回连）
  bool manualDisconnect = false;

  StreamSubscription? _connSub;
  Timer? _rssiTimer;
  Timer? _reconnectTimer;
  final Map<String, StreamSubscription> _notifySubs = {};

  DeviceSession(this.device) {
    _connSub = device.connectionState.listen(_onConnState);
  }

  String get mac => device.remoteId.str;
  String get name => device.platformName.isNotEmpty ? device.platformName : '未知设备';

  bool get isConnected =>
      state.value == BluetoothConnectionState.connected;
  Future<void> connectNow() async {
    manualDisconnect = false;
    _reconnectTimer?.cancel();
    state.value = BluetoothConnectionState.connecting;
    try {
      await device.connect(
          timeout: const Duration(seconds: 15), autoConnect: false);
    } catch (e) {
      // 连接失败：保留会话，页面显示"未连接"，可点回连
      state.value = BluetoothConnectionState.disconnected;
      BleEngine.instance.logEvent(mac, '连接失败: $e');
    }
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
    _reconnectTimer?.cancel();
    manualDisconnect = false;
    BleEngine.instance.logEvent(mac, '连接成功，等待发现服务');
    try {
      // 先请求大 MTU（安卓），提升单包发送长度
      try {
        final m = await device.requestMtu(512);
        mtu = m;
        BleEngine.instance.logEvent(mac, 'MTU 协商为 $m');
      } catch (_) {
        try {
          mtu = device.mtuNow;
        } catch (_) {}
      }
      services = await device.discoverServices();
      servicesReady.value = true;
      BleEngine.instance.logEvent(mac, '连接成功，并成功发现服务');
      // 发送目标不自动点亮：由用户在蓝牙服务页点击选择（最新点击为准）
      // ——除非扫描页三点菜单开了「自动特征」且 UUID 匹配
      await _applyAutoFeature();
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

  /// 自动特征：服务 UUID 匹配时，自动点亮发送目标特征 + 开启通知特征
  Future<void> _applyAutoFeature() async {
    final e = BleEngine.instance;
    if (!e.autoFeatureEnabled) return;
    bool uuidMatch(String a, String b) {
      if (a.isEmpty || b.isEmpty) return false;
      final x = a.toLowerCase().replaceAll('-', '');
      final y = b.toLowerCase().replaceAll('-', '');
      return x == y || x.endsWith(y) || y.endsWith(x);
    }

    for (final svc in services) {
      if (!uuidMatch(svc.uuid.str, e.autoFeatServiceUuid)) continue;
      autoFeatureMatched.value = true;
      e.logEvent(mac, '自动特征：服务匹配 ${svc.uuid.str}');
      for (final c in svc.characteristics) {
        if (uuidMatch(c.uuid.str, e.autoFeatWriteUuid) &&
            (c.properties.write || c.properties.writeWithoutResponse)) {
          targetChar.value = c;
          e.logEvent(mac, '自动特征：发送目标已点亮 ${shortUuid(c.uuid.str)}');
        }
        if (uuidMatch(c.uuid.str, e.autoFeatNotifyUuid) &&
            (c.properties.notify || c.properties.indicate)) {
          await setNotify(c, true);
        }
      }
      return;
    }
    e.logEvent(mac, '自动特征：未找到匹配的服务 UUID，跳过');
  }

  /// 自动特征匹配成功（设备页监听它跳到实时日志 Tab）
  final ValueNotifier<bool> autoFeatureMatched = ValueNotifier(false);

  void _onDisconnected() {
    _rssiTimer?.cancel();
    for (final sub in _notifySubs.values) {
      sub.cancel();
    }
    _notifySubs.clear();
    servicesReady.value = false;
    if (manualDisconnect) {
      BleEngine.instance.logEvent(mac, '已断开连接');
    } else {
      BleEngine.instance.logEvent(mac, '连接已断开');
      // 自动回连（扫描页"连接设置"里开启后生效）
      if (BleEngine.instance.autoReconnect) {
        _scheduleReconnect();
      }
    }
    // 注意：不移除会话。界面变灰 + 回连按钮。
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (manualDisconnect ||
          !BleEngine.instance.autoReconnect ||
          state.value == BluetoothConnectionState.connected ||
          state.value == BluetoothConnectionState.connecting) {
        _reconnectTimer?.cancel();
        return;
      }
      BleEngine.instance.logEvent(mac, '自动回连中...');
      connectNow();
    });
  }

  void cancelReconnect() {
    _reconnectTimer?.cancel();
  }

  /// 用户手动断开
  Future<void> disconnect() async {
    manualDisconnect = true;
    _reconnectTimer?.cancel();
    try {
      await device.disconnect();
    } catch (_) {
      state.value = BluetoothConnectionState.disconnected;
    }
  }

  /// 统计清零
  void resetStats() {
    recvPkts = 0;
    recvBytes = 0;
    sentOkPkts = 0;
    sentOkBytes = 0;
    sentFailPkts = 0;
    statsBump.value++;
  }

  /// 开关通知（乐观更新：点击立即点亮/熄灭，失败再回退）
  Future<bool> setNotify(BluetoothCharacteristic c, bool enable) async {
    final key = c.uuid.str.toLowerCase();
    // 乐观更新 UI
    notifyState[key] = enable;
    notifyBump.value++;
    try {
      await c.setNotifyValue(enable);
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
      } else if (!enable) {
        _notifySubs.remove(c.uuid.str)?.cancel();
      }
      BleEngine.instance.logEvent(
          mac, '[${shortUuid(c.uuid.str)}] Notification${enable ? '开启' : '关闭'}');
      return true;
    } catch (e) {
      // 失败回退
      notifyState[key] = !enable;
      notifyBump.value++;
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
    _reconnectTimer?.cancel();
    _connSub?.cancel();
    for (final sub in _notifySubs.values) {
      sub.cancel();
    }
    notifyBump.dispose();
    autoFeatureMatched.dispose();
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

  /// 去重后、按 RSSI 排序的原始扫描结果（未过滤，过滤在 UI 层做）
  final ValueNotifier<List<ScanResult>> scanResults = ValueNotifier([]);

  /// 每台设备最新一次广播（广播数据页用）
  final Map<String, ScanResult> latestResults = {};

  /// 每台设备的 RSSI 历史曲线（广播数据页画图用，带时间戳，滑窗 40 秒）
  final Map<String, List<RssiSample>> rssiHistory = {};

  void addRssiSample(String mac, int rssi) {
    if (rssi < 0 && rssi >= -100) {
      final h = rssiHistory.putIfAbsent(mac, () => []);
      h.add(RssiSample(DateTime.now(), rssi));
      final cutoff = DateTime.now().subtract(const Duration(seconds: 40));
      h.removeWhere((s) => s.t.isBefore(cutoff));
    }
  }

  /// 过滤条件变化时 +1，通知扫描页重算
  final ValueNotifier<int> filterBump = ValueNotifier(0);

  /// 会话，key = mac（断开后保留，支持回连）
  final Map<String, DeviceSession> sessions = {};
  final ValueNotifier<int> sessionsBump = ValueNotifier(0);

  /// 全量日志（跨设备都带 mac，页面自行过滤）
  final ValueNotifier<List<LogEntry>> logs = ValueNotifier([]);
  static const int _maxLogs = 5000;

  /// 扫描过滤条件（默认配置对标原版：BLE✓ 名称非空✓ RSSI≥-50）
  String nameFilter = '';
  String uuidFilter = '';
  bool onlyBle = true;
  bool onlyNamed = true;
  int rssiThreshold = -70; // 默认 -70（v1.5 由 -50 改）

  bool loopScan = false;
  int scanPeriodSec = 10;

  /// 断线自动回连（设备断电重上电后自动重连）
  bool autoReconnect = false;

  /// ---- 日志行格式配置（实时日志三点菜单"日志格式设置"里改）----
  /// 行结构：时间> [主题] 动作: "数据"
  bool logShowTime = true;
  bool logShowTag = true;
  bool logShowDir = true;
  bool logShowQuote = true;

  /// ---- 自定义按键云端同步链接（链接1/2/3...）----
  List<String> cloudLinks = ['https://notepad.1976f.com/LXHL/R4-7'];

  /// ---- 自动特征（扫描页三点菜单设置）：连接后自动点亮发送目标 + 开通知 ----
  bool autoFeatureEnabled = false;
  String autoFeatServiceUuid = ''; // 完整服务 UUID
  String autoFeatWriteUuid = ''; // 发送目标特征 UUID
  String autoFeatNotifyUuid = ''; // 通知特征 UUID

  /// ---- 外围模式配置 ----
  String advLocalName = 'BLE调试助手';
  String advServiceUuid = '0000ff11-0000-1000-8000-00805f9b34fb';
  String advCharServiceUuid = '0000ff00-0000-1000-8000-00805f9b34fb';
  String advCharUuid = '0000ff01-0000-1000-8000-00805f9b34fb';
  String advCharData = '010203040506'; // 特征数据（中央读取时返回）
  String advNotifyData = '060504030201'; // 通知数据（响应模式发送）
  int advResponseMode = 0; // 0=被写入时回复 1=循环发送
  int advLoopDelayMs = 500;
  List<ReplyRule> replyRules = [];

  Future<void> loadSettings() async {
    final sp = await SharedPreferences.getInstance();
    autoReconnect = sp.getBool('auto_reconnect') ?? false;
    autoFeatureEnabled = sp.getBool('auto_feature_enabled') ?? false;
    autoFeatServiceUuid = sp.getString('auto_feat_service') ?? '';
    autoFeatWriteUuid = sp.getString('auto_feat_write') ?? '';
    autoFeatNotifyUuid = sp.getString('auto_feat_notify') ?? '';
    logShowTime = sp.getBool('log_show_time') ?? true;
    logShowTag = sp.getBool('log_show_tag') ?? true;
    logShowDir = sp.getBool('log_show_dir') ?? true;
    logShowQuote = sp.getBool('log_show_quote') ?? true;
    final links = sp.getStringList('cloud_links');
    if (links != null && links.isNotEmpty) cloudLinks = links;
    advLocalName = sp.getString('adv_local_name') ?? advLocalName;
    advServiceUuid = sp.getString('adv_service_uuid') ?? advServiceUuid;
    advCharServiceUuid =
        sp.getString('adv_char_service_uuid') ?? advCharServiceUuid;
    advCharUuid = sp.getString('adv_char_uuid') ?? advCharUuid;
    advCharData = sp.getString('adv_char_data') ?? advCharData;
    advNotifyData = sp.getString('adv_notify_data') ?? advNotifyData;
    advResponseMode = sp.getInt('adv_response_mode') ?? 0;
    advLoopDelayMs = sp.getInt('adv_loop_delay') ?? 500;
    final rules = sp.getString('adv_reply_rules');
    if (rules != null && rules.isNotEmpty) {
      try {
        final arr = jsonDecode(rules) as List;
        replyRules = arr
            .whereType<Map>()
            .map((e) => ReplyRule.fromJson(e.cast<String, dynamic>()))
            .toList();
      } catch (_) {
        replyRules = [];
      }
    }
    loadCmds();
  }

  Future<void> saveAutoFeature() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('auto_feature_enabled', autoFeatureEnabled);
    await sp.setString('auto_feat_service', autoFeatServiceUuid);
    await sp.setString('auto_feat_write', autoFeatWriteUuid);
    await sp.setString('auto_feat_notify', autoFeatNotifyUuid);
  }

  Future<void> saveLogFormat() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('log_show_time', logShowTime);
    await sp.setBool('log_show_tag', logShowTag);
    await sp.setBool('log_show_dir', logShowDir);
    await sp.setBool('log_show_quote', logShowQuote);
  }

  Future<void> saveCloudLinks() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('cloud_links', cloudLinks);
  }

  Future<void> saveAdvConfig() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('adv_local_name', advLocalName);
    await sp.setString('adv_service_uuid', advServiceUuid);
    await sp.setString('adv_char_service_uuid', advCharServiceUuid);
    await sp.setString('adv_char_uuid', advCharUuid);
    await sp.setString('adv_char_data', advCharData);
    await sp.setString('adv_notify_data', advNotifyData);
    await sp.setInt('adv_response_mode', advResponseMode);
    await sp.setInt('adv_loop_delay', advLoopDelayMs);
    await sp.setString(
        'adv_reply_rules', jsonEncode(replyRules.map((r) => r.toJson()).toList()));
  }

  Future<void> setAutoReconnect(bool v) async {
    autoReconnect = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('auto_reconnect', v);
    if (!v) {
      for (final s in sessions.values) {
        s.cancelReconnect();
      }
    } else {
      // 已断开且非手动断开的会话，立即开始回连
      for (final s in sessions.values) {
        if (!s.isConnected && !s.manualDisconnect) {
          s.connectNow();
        }
      }
    }
  }

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
      final map = <String, ScanResult>{};
      for (final r in results) {
        final mac = r.device.remoteId.str;
        map[mac] = r;
        latestResults[mac] = r;
        BleEngine.instance.addRssiSample(mac, r.rssi);
      }
      final list = map.values.toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));
      scanResults.value = list;
    });
  }

  /// UI 层调用：按当前过滤条件筛选扫描结果（返回新列表，已按 RSSI 降序）
  List<ScanResult> applyFilters(List<ScanResult> input) {
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

  /// 过滤条件变化后调用，让扫描页立即重算
  void notifyFilters() => filterBump.value++;

  // ---- 连接 ----
  DeviceSession? sessionOf(String mac) => sessions[mac];

  /// 连接（已存在会话则回连）
  Future<void> connect(BluetoothDevice device) async {
    final mac = device.remoteId.str;
    final existing = sessions[mac];
    if (existing != null) {
      await existing.connectNow();
      return;
    }
    final s = DeviceSession(device);
    sessions[mac] = s;
    sessionsBump.value++;
    await s.connectNow();
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

class RssiSample {
  final DateTime t;
  final int v;
  RssiSample(this.t, this.v);
}

/// UUID 缩写：取后 4 位，如 ffe1
String shortUuid(String uuid) {
  final u = uuid.toLowerCase().replaceAll('-', '');
  return u.length >= 4 ? u.substring(u.length - 4) : u;
}
