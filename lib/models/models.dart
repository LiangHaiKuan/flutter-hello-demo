/// 实时日志条目
enum LogDir { notify, indicate, sendOk, sendFail, read, event }class LogEntry {
  final DateTime time;
  final LogDir dir;
  final String tag; // 特征值 UUID 缩写或事件名
  final List<int> bytes;
  final String? message; // 事件类日志的文本

  const LogEntry({
    required this.time,
    required this.dir,
    required this.tag,
    this.bytes = const [],
    this.message,
  });

  String get timeStr =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}.'
      '${time.millisecond.toString().padLeft(3, '0')}';

  /// 日志行显示的方向文字（对标原版：成功写入 / Notify / 读取）
  String get dirStr {
    switch (dir) {
      case LogDir.notify:
        return 'Notify:';
      case LogDir.indicate:
        return 'Indicate:';
      case LogDir.sendOk:
        return '成功写入:';
      case LogDir.sendFail:
        return '写入失败:';
      case LogDir.read:
        return '读取:';
      case LogDir.event:
        return message ?? '';
    }
  }
}

/// 自定义按键命令（持久化到 SharedPreferences）
class FastCmd {
  final String id;
  String name;
  bool hexMode;
  String data; // hex: 空格分隔字节；ascii: 原文
  bool enabled;
  int order;

  FastCmd({
    required this.id,
    required this.name,
    required this.hexMode,
    required this.data,
    this.enabled = true,
    this.order = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hexMode': hexMode,
        'data': data,
        'enabled': enabled,
        'order': order,
      };

  factory FastCmd.fromJson(Map<String, dynamic> j) => FastCmd(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        hexMode: (j['hexMode'] ?? true) as bool,
        data: (j['data'] ?? '') as String,
        enabled: (j['enabled'] ?? true) as bool,
        order: (j['order'] ?? 0) as int,
      );

  /// 预览文本（卡片上"数据："那一行）
  String preview() {
    if (hexMode) return data.toUpperCase();
    return data;
  }

  /// 导出为 fast_cmds 文件行格式：序号→名称,格式,数据
  String exportLine(int index) =>
      '$index\u2192$name,${hexMode ? 'hex' : 'us-ascii'},${hexMode ? data.toUpperCase() : data}';
}

/// fast_cmds 解析结果：解析出的命令 + 跳过的无效行数
class FastCmdParseResult {
  final List<FastCmd> cmds;
  final int skippedLines; // 无效行（含注释行）
  FastCmdParseResult(this.cmds, this.skippedLines);
}

/// 从 fast_cmds 文本（多行）解析命令列表。
///
/// 规则（对标旧软件导出格式）：
/// - `//` 开头的行是注释，跳过；
/// - 行格式：`序号→名称,格式,数据`（→ 也可以是制表符），不满足格式的行直接跳过；
/// - 格式字段：hex（或任意非 ascii 文本）→ hex 模式；us-ascii/ascii → ascii 模式。
FastCmdParseResult parseFastCmds(String text) {
  final result = <FastCmd>[];
  var skipped = 0;
  final lines = text.split(RegExp(r'\r?\n'));
  var order = 0;
  for (final line in lines) {
    final l = line.trim();
    if (l.isEmpty) continue;
    if (l.startsWith('//') || l.startsWith('#')) {
      skipped++;
      continue;
    }
    // 格式：序号→名称,格式,数据（箭头可能是 → 字符或制表符）
    final arrow = l.indexOf('\u2192');
    final tab = l.indexOf('\t');
    final sep = (arrow >= 0 && (tab < 0 || arrow < tab)) ? arrow : tab;
    String body;
    if (sep >= 0) {
      body = l.substring(sep + 1);
    } else {
      body = l; // 兼容无序号的行
    }
    final segs = body.split(',');
    if (segs.length < 3) {
      skipped++;
      continue;
    }
    final name = segs[0].trim();
    final fmt = segs[1].trim().toLowerCase();
    final data = segs.sublist(2).join(',').trim();
    if (name.isEmpty || data.isEmpty) {
      skipped++;
      continue;
    }
    // 格式必须能识别（hex / ascii 类），识别不了视为无效行跳过
    final isAscii = fmt == 'us-ascii' || fmt == 'ascii';
    final isHex = fmt == 'hex' || fmt == '0x' || fmt == '16进制';
    if (!isAscii && !isHex) {
      skipped++;
      continue;
    }
    result.add(FastCmd(
      id: DateTime.now().microsecondsSinceEpoch.toString() + '_$order',
      name: name,
      hexMode: !isAscii,
      data: data,
      order: order,
    ));
    order++;
  }
  return FastCmdParseResult(result, skipped);
}

/// 外围模式"收到什么回复什么"规则
class ReplyRule {
  String match; // 收到内容（hex，无空格大写；空 = 收到任何数据都回复）
  String reply; // 回复内容（按发送编码设置解析）
  bool hexMode; // 匹配与回复是否为 hex
  bool enabled;

  ReplyRule({
    required this.match,
    required this.reply,
    this.hexMode = true,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        'match': match,
        'reply': reply,
        'hexMode': hexMode,
        'enabled': enabled,
      };

  factory ReplyRule.fromJson(Map<String, dynamic> j) => ReplyRule(
        match: (j['match'] ?? '') as String,
        reply: (j['reply'] ?? '') as String,
        hexMode: (j['hexMode'] ?? true) as bool,
        enabled: (j['enabled'] ?? true) as bool,
      );

  /// 导出为文本行：收到A→回复B
  String exportLine(int index) =>
      '$index\u2192${match.isEmpty ? '(任意)' : match} \u2192 $reply';
}
