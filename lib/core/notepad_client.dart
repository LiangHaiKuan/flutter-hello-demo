import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 1paper (notepad.1976f.com) 云端文本的读写客户端。
///
/// 协议（已实测验证）：
/// - socket.io v4 (EIO=4) over WebSocket，端点 `/socket.io/`；
/// - RPC：`get {id}` → `{note}`；`save {id, p, h}` → `null` 成功 / `{errcode}` 失败；
/// - p 是【按行】的 patch：`[{a:[起始行号, 替换行数], b:[新行...]}]`，
///   服务端把 patch 应用到当前内容后做 DJB2 哈希校验（h = 新内容哈希）；
/// - 全量覆盖 = 读取当前内容 → 用一行 patch 替换全部行 → save。
class NotepadClient {
  NotepadClient._();

  WebSocket? _ws;
  int _ackId = 0;
  final Map<int, Completer<dynamic>> _acks = {};
  Completer<void>? _nsCompleter;
  bool _connected = false;

  /// 解析云端链接：https://notepad.1976f.com/LXHL/R4-7
  /// 返回 (host, port, scheme, noteId)
  static ({
    String scheme,
    String host,
    int port,
    String noteId,
  })? parseNoteUrl(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || u.host.isEmpty) return null;
    var noteId = u.path;
    if (noteId.startsWith('/')) noteId = noteId.substring(1);
    if (noteId.isEmpty) return null;
    return (
      scheme: u.scheme.isEmpty ? 'https' : u.scheme,
      host: u.host,
      port: u.port == 0 ? (u.scheme == 'http' ? 80 : 443) : u.port,
      noteId: noteId,
    );
  }

  /// 读取云端文本
  Future<String> readNote(String url) async {
    final info = parseNoteUrl(url);
    if (info == null) throw Exception('链接格式不对');
    await _connect(info.scheme, info.host, info.port);
    final res = await _emit('get', {'id': info.noteId});
    if (res is Map && res['note'] is String) {
      return res['note'] as String;
    }
    throw Exception('云端读取失败（文档不存在？）');
  }

  /// 全量覆盖写入云端文本。成功返回 true。
  Future<bool> writeNote(String url, String content) async {
    final info = parseNoteUrl(url);
    if (info == null) throw Exception('链接格式不对');
    await _connect(info.scheme, info.host, info.port);
    // 1. 读当前内容（拿到行数，patch 的 a 才能对上）
    final cur = await _emit('get', {'id': info.noteId});
    final oldNote =
        (cur is Map && cur['note'] is String) ? cur['note'] as String : '';
    final oldLines = oldNote.split('\n');
    // 2. 全量替换 patch（按行）
    final newLines = content.split('\n');
    final patch = [
      {'a': [0, oldLines.length], 'b': newLines},
    ];
    // 3. save（哈希 = 新内容的 DJB2）
    final res = await _emit('save', {
      'id': info.noteId,
      'p': patch,
      'h': djb2(content),
    });
    if (res == null) return true;
    if (res is Map && res['errcode'] != null) {
      // 10001 = 哈希不匹配（期间被别人改了），重试一次
      final retry = await _emit('save', {
        'id': info.noteId,
        'p': patch,
        'h': djb2(content),
      });
      if (retry == null) return true;
      throw Exception('云端写入失败 (errcode=${res['errcode']})');
    }
    return true;
  }

  Future<void> _connect(String scheme, String host, int port) async {
    if (_connected) return;
    final wsScheme = scheme == 'https' ? 'wss' : 'ws';
    final wsUrl = '$wsScheme://$host:$port/socket.io/?EIO=4&transport=websocket';
    _acks.clear();
    _nsCompleter = Completer<void>();
    _ws = await WebSocket.connect(wsUrl);
    _ws!.listen((data) {
      if (data is! String) return;
      _onPacket(data);
    }, onDone: () {
      _connected = false;
      for (final c in _acks.values) {
        if (!c.isCompleted) c.completeError(Exception('云端连接已断开'));
      }
      _acks.clear();
    }, onError: (e) {
      _connected = false;
    });

    // 等 namespace 握手完成（服务端发 40 后我们标记可用）
    await _nsCompleter!.future.timeout(const Duration(seconds: 15));
    _connected = true;
  }

  void _onPacket(String pkt) {
    if (pkt.startsWith('0')) {
      // engine.io open → 连接 socket.io 命名空间
      _ws?.add('40');
      return;
    }
    if (pkt.startsWith('40')) {
      // namespace connected
      if (_nsCompleter != null && !_nsCompleter!.isCompleted) {
        _nsCompleter!.complete();
      }
      return;
    }
    if (pkt == '2') {
      // engine.io ping（精确匹配，别把 "42..." 事件帧误当成 ping）
      _ws?.add('3');
      return;
    }
    if (pkt.startsWith('43')) {
      // ACK: 43<id>[json]
      final rest = pkt.substring(2);
      var i = 0;
      while (i < rest.length && rest.codeUnitAt(i) >= 0x30 && rest.codeUnitAt(i) <= 0x39) {
        i++;
      }
      final id = int.tryParse(rest.substring(0, i));
      final payload = rest.substring(i);
      dynamic data;
      try {
        data = payload.isEmpty ? null : jsonDecode(payload);
      } catch (_) {
        data = null;
      }
      if (id != null && _acks.containsKey(id)) {
        final c = _acks.remove(id)!;
        if (!c.isCompleted) c.complete(data);
      }
      return;
    }
    // 42xx = 服务器广播事件（noteUpdate 等），忽略
  }

  Future<dynamic> _emit(String event, dynamic args) {
    final id = ++_ackId;
    final c = Completer<dynamic>();
    _acks[id] = c;
    _ws!.add('42$id${jsonEncode([event, args])}');
    return c.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _acks.remove(id);
      throw Exception('云端请求超时');
    });
  }

  /// DJB2 哈希（与服务端一致的实现：从后往前，t = t*33 ^ code，无符号 32 位）
  static int djb2(String s) {
    var t = 5381;
    var i = s.length;
    while (i > 0) {
      i--;
      t = (t * 33) ^ s.codeUnitAt(i);
      t = t & 0xFFFFFFFF;
    }
    return t;
  }

  void dispose() {
    _connected = false;
    try {
      _ws?.close();
    } catch (_) {}
    _ws = null;
    _acks.clear();
  }
}
