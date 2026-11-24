import 'dart:convert';
import 'dart:typed_data';

import 'package:gbk_codec/gbk_codec.dart';

/// 文本编码格式（对标原版"编码"选择：hex / us-ascii / utf-8 / gbk 等常用项）
enum TextCodec { hex, ascii, utf8, gbk }

extension TextCodecX on TextCodec {
  String get label {
    switch (this) {
      case TextCodec.hex:
        return 'hex';
      case TextCodec.ascii:
        return 'us-ascii';
      case TextCodec.utf8:
        return 'utf-8';
      case TextCodec.gbk:
        return 'gbk';
    }
  }

  static TextCodec fromLabel(String s) {
    switch (s.toLowerCase()) {
      case 'hex':
        return TextCodec.hex;
      case 'us-ascii':
      case 'ascii':
        return TextCodec.ascii;
      case 'utf-8':
      case 'utf8':
        return TextCodec.utf8;
      case 'gbk':
      case 'gb2312':
        return TextCodec.gbk;
      default:
        return TextCodec.hex;
    }
  }
}

/// hex / 文本 数据解析与显示工具
class HexUtil {
  HexUtil._();

  /// 解析用户输入为字节数据。
  /// hex 模式：支持 "aa 00 bb" / "aa00bb" / "0xAA 0x0B"
  /// 文本模式：按对应编码编码
  /// 解析失败返回 null。
  static Uint8List? parse(String input, TextCodec codec) {
    if (codec == TextCodec.hex) {
      var cleaned = input.trim().toLowerCase();
      if (cleaned.isEmpty) return null;
      cleaned = cleaned.replaceAll(RegExp(r'0x'), ' ');
      cleaned = cleaned.replaceAll(RegExp(r'[\s,]+'), ' ');
      final parts =
          cleaned.trim().split(' ').where((p) => p.isNotEmpty).toList();
      // 允许整串无空格写法 aa00bb11
      if (parts.length == 1 && parts[0].length > 2 && parts[0].length.isEven) {
        final s = parts[0];
        parts.clear();
        for (var i = 0; i + 1 < s.length; i += 2) {
          parts.add(s.substring(i, i + 2));
        }
      }
      final bytes = <int>[];
      for (final p in parts) {
        final v = int.tryParse(p, radix: 16);
        if (v == null || v < 0 || v > 255) return null;
        bytes.add(v);
      }
      if (bytes.isEmpty) return null;
      return Uint8List.fromList(bytes);
    }
    if (input.isEmpty) return null;
    switch (codec) {
      case TextCodec.ascii:
        return Uint8List.fromList(latin1.encode(input));
      case TextCodec.utf8:
        return Uint8List.fromList(utf8.encode(input));
      case TextCodec.gbk:
        return Uint8List.fromList(gbk_bytes.encode(input));
      default:
        return null;
    }
  }

  /// 字节 → "FF 55 AA" 大写空格分隔
  static String toHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
  }

  /// 字节 → 可打印 ascii（不可见字符用 . 代替）
  static String toAscii(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      if (b >= 0x20 && b <= 0x7E) {
        sb.writeCharCode(b);
      } else {
        sb.write('.');
      }
    }
    return sb.toString();
  }

  /// 字节 → 对应编码文本
  static String toText(List<int> bytes, TextCodec codec) {
    switch (codec) {
      case TextCodec.hex:
        return toHex(bytes);
      case TextCodec.ascii:
        return toAscii(bytes);
      case TextCodec.utf8:
        return utf8.decode(bytes, allowMalformed: true);
      case TextCodec.gbk:
        return gbk_bytes.decode(bytes);
    }
  }

  /// 显示用：按当前格式输出
  static String display(List<int> bytes, TextCodec codec) {
    return toText(bytes, codec);
  }
}

/// 已知 GATT UUID 的友好名称映射
class UuidNames {
  UuidNames._();

  static const Map<String, String> services = {
    '00001800': 'Generic Access',
    '00001801': 'Generic Attribute',
    '0000180a': 'Device Information',
    '0000180f': 'Battery Service',
    '0000180d': 'Heart Rate',
    '0000180c': 'User Data',
    '6e400001-b5a3-f393-e0a9-e50e24dcca9e': 'Nordic UART Service',
    '0000fe95': 'Xiaomi Service',
    '0000fee7': 'Tile Service',
    '0000fef3': 'Anki Service',
  };

  static const Map<String, String> characteristics = {
    '00002a00': 'Device Name',
    '00002a01': 'Appearance',
    '00002a02': 'Peripheral Preferred Connection Parameters',
    '00002a04': 'Peripheral User Description',
    '00002a05': 'Service Changed',
    '00002a19': 'Battery Level',
    '00002a23': 'System ID',
    '00002a24': 'Model Number',
    '00002a25': 'Serial Number',
    '00002a26': 'Firmware Revision',
    '00002a27': 'Hardware Revision',
    '00002a28': 'Software Revision',
    '00002a29': 'Manufacturer Name',
    '00002a37': 'Heart Rate Measurement',
    '6e400002-b5a3-f393-e0a9-e50e24dcca9e': 'RX Characteristic',
    '6e400003-b5a3-f393-e0a9-e50e24dcca9e': 'TX Characteristic',
  };

  static String serviceName(String uuid) {
    final u = uuid.toLowerCase();
    if (u.length >= 8 && services.containsKey(u.substring(0, 8))) {
      return services[u.substring(0, 8)]!;
    }
    if (services.containsKey(u)) return services[u]!;
    return 'Unknown Service';
  }

  static String charName(String uuid) {
    final u = uuid.toLowerCase();
    if (u.length >= 8 && characteristics.containsKey(u.substring(0, 8))) {
      return characteristics[u.substring(0, 8)]!;
    }
    if (characteristics.containsKey(u)) return characteristics[u]!;
    return 'Unknown Characteristic';
  }
}
