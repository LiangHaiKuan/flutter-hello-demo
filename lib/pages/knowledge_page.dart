import 'package:flutter/material.dart';

/// 蓝牙科普页
/// section: 'gatt' = 蓝牙服务科普（设备页入口） | 'adv' = 广播包科普（广播数据页入口）
class KnowledgePage extends StatelessWidget {
  final String section;
  final String name;

  const KnowledgePage({super.key, required this.section, this.name = ''});

  @override
  Widget build(BuildContext context) {
    final isGatt = section == 'gatt';
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        title: Text(isGatt ? '蓝牙服务科普' : '蓝牙广播包科普',
            style: const TextStyle(fontSize: 17)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: isGatt ? _gattSections() : _advSections(),
      ),
    );
  }

  // ================= 通用小组件 =================

  Widget _h1(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(t,
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFFF57C00))),
      );

  Widget _p(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(t,
            style: const TextStyle(fontSize: 14, height: 1.6, color: Colors.black87)),
      );

  Widget _bullet(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 9),
              child: Icon(Icons.fiber_manual_record, size: 6, color: Colors.grey),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(t,
                  style: const TextStyle(
                      fontSize: 14, height: 1.55, color: Colors.black87)),
            ),
          ],
        ),
      );

  Widget _table(List<List<String>> rows, {List<double>? flex}) {
    return Table(
      border: TableBorder.all(color: Colors.grey.shade400, width: 0.5),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: flex == null
          ? null
          : {
              for (var i = 0; i < flex.length; i++) i: FlexColumnWidth(flex[i]),
            },
      children: [
        for (var r = 0; r < rows.length; r++)
          TableRow(
            decoration: BoxDecoration(
                color: r == 0 ? const Color(0xFFF5F5F5) : Colors.white),
            children: [
              for (final cell in rows[r])
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    cell,
                    style: TextStyle(
                      fontSize: r == 0 ? 13 : 13,
                      fontWeight: r == 0 ? FontWeight.bold : FontWeight.normal,
                      fontFamily: r == 0 ? null : 'monospace',
                      color: r == 0 ? Colors.orange : Colors.black87,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _code(String t) => Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F7F7),
          border: Border.all(color: Colors.grey.shade400),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(t,
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 13, height: 1.5)),
      );

  // ================= 蓝牙服务科普（GATT） =================

  List<Widget> _gattSections() {
    return [
      _h1('什么是蓝牙服务（Service）？'),
      _p('BLE 设备连接后，手机会从设备上"发现"一棵服务树。这棵树叫 GATT（Generic Attribute Profile），是蓝牙联盟（Bluetooth SIG）规定的标准数据组织方式。'),
      _bullet('Service（服务）：一个功能块，例如"电池电量服务""透传服务"。每个服务有唯一 UUID。'),
      _bullet('Characteristic（特征值）：服务下面的具体数据点，是真正读写的地方。例如"电量值""串口接收通道"。'),
      _bullet('Properties（属性）：声明这个特征值能做什么 —— READ（读）、WRITE（写）、WRITE_NO_RESPONSE（无响应写，更快但无确认）、NOTIFY（通知，设备主动推送）、INDICATE（指示，类似通知但需要手机确认）。'),
      _h1('蓝牙联盟规定的标准服务（16位短UUID）'),
      _p('UUID 形如 0000xxxx-0000-1000-8000-00805f9b34fb 的是蓝牙联盟官方分配的标准服务，xxxx 就是下面表里的短码：'),
      _table([
        ['UUID', '服务名称', '用途'],
        ['0x1800', 'Generic Access', '设备名称、外观等基础信息'],
        ['0x1801', 'Generic Attribute', 'GATT 协议自身的管理'],
        ['0x180A', 'Device Information', '厂商、型号、固件版本号等'],
        ['0x180F', 'Battery Service', '电池电量（特征值 0x2A19，0~100%）'],
        ['0x180D', 'Heart Rate', '心率'],
        ['0x181A', 'Environmental Sensing', '温湿度等环境传感器'],
        ['0xFFE0', '（厂商自定义）', '国产透传模块最常用的透传服务，特征值多为 0xFFE1'],
        ['0x6E400001', 'Nordic UART', 'Nordic 芯片的串口透传（RX: 6E400002 / TX: 6E400003）'],
      ], flex: [2, 3, 6]),
      _p('除了表里这些官方标准，其余 UUID 都是厂商自定义的。你们产品的私有服务（如 6E400003 这种 Nordic 格式）就属于自定义透传。'),
      _h1('读、写、通知是怎么配合的？'),
      _bullet('手机 → 设备：对可写特征值 WRITE 一包数据（write）；不需要设备回复确认就用 WRITE_NO_RESPONSE，速度快。'),
      _bullet('设备 → 手机：手机先对 NOTIFY 特征值"开启通知"（订阅），之后设备有数据就主动推给手机，这就是你在实时日志里看到的 Notify 包。'),
      _bullet('INDICATE 和 NOTIFY 的区别：INDICATE 每包都要手机回 ACK，可靠但慢；NOTIFY 不回，快但可能丢。'),
      _bullet('发送目标：本 App 发送栏发出的数据走哪个特征值，取决于你选的"发送目标"（在蓝牙服务页长按写入图标选择）。'),
      _h1('MTU 是什么？'),
      _p('MTU（Maximum Transmission Unit）是一次 BLE 交互最大字节数，默认 23 字节，减去 3 字节协议头，单包实际最多发 20 字节。'),
      _p('连接后把 MTU 协商到 512，单包就能发 509 字节 —— 本 App 已在连接成功后自动请求 512，菜单里也可以手动修改。发大文件前把 MTU 拉满能显著提速。'),
      _h1('常见调试疑问'),
      _bullet('为什么服务里有特征值读写不了？→ 看 Properties，没有 WRITE 权限就写不了，没有 NOTIFY 就订阅不了。'),
      _bullet('为什么 Notify 收到的数据和协议对不上？→ 先确认订阅的是正确的特征值（透传模块一般只有一个 NOTIFY 通道）。'),
      _bullet('为什么一包最多 20 字节？→ MTU 没协商上去，或设备固件只支持默认 MTU。'),
    ];
  }

  // ================= 广播包科普（ADV） =================

  List<Widget> _advSections() {
    return [
      _h1('广播包是什么？'),
      _p('BLE 设备没被连接之前，会每隔一段时间（一般 20ms~10s）向外发"广播包"（Advertising Packet），告诉周围："我在这里，我叫这个名字，我支持这些功能。"手机扫描收到的就是它。'),
      _h1('广播包的结构：一串 LEN/TYPE/VALUE'),
      _p('广播数据由若干个"AD 结构"（AD Structure）首尾拼接而成，每个结构的格式都是三段：'),
      _code('01 06 03 0A 00 09 09 33 37 39 33 32 31 39\n|\  |  |   |  |  |  \_______ VALUE _______/\n|   | |   | |  |  \_ TYPE=0x09 完整设备名\n|   | |   | |  \_ LEN=9（TYPE+VALUE 共 9 字节）\n|   | |   | \_ TYPE=0x0A 发射功率\n|   | |   \_ LEN=3\n|   | \_ VALUE=0x06\n|   \_ TYPE=0x01 Flags\n\_ LEN=2'),
      _bullet('LEN（1字节）：后面 TYPE + VALUE 一共多少字节（不含 LEN 自己）。'),
      _bullet('TYPE（1字节）：这段数据是什么类型，由蓝牙联盟统一编号。'),
      _bullet('VALUE（LEN-1 字节）：实际数据。'),
      _h1('常见的 TYPE 类型表（蓝牙联盟规定）'),
      _table([
        ['TYPE', '名称', 'VALUE 含义'],
        ['0x01', 'Flags', '设备模式标志，0x06 = 可连接+不支持传统蓝牙'],
        ['0x02/0x03', '16位服务UUID', '设备提供的服务列表（不完整/完整）'],
        ['0x06/0x07', '128位服务UUID', '自定义服务的完整 UUID 列表'],
        ['0x08/0x09', '设备名称', '短名 / 完整名（就是扫描列表显示的名字）'],
        ['0x0A', '发射功率', '设备发射功率 dBm，有符号数'],
        ['0x16', '服务数据', '某服务对外广播的数据（如 iBeacon 类）'],
        ['0x19', '外观', '设备图标类别（手环、鼠标…）'],
        ['0xFF', '厂商自定义数据', '前 2 字节是厂商 ID，后面任意 —— iBeacon 就用它'],
      ], flex: [2, 3, 6]),
      _h1('手把手解析一个例子'),
      _p('假设原始广播数据是：'),
      _code('02 01 06 0A 09 54 45 53 54 2D 44 45 56 49 43 45'),
      _bullet('第 1 段：LEN=02，TYPE=01（Flags），VALUE=06 → 可连接的通用广播。'),
      _bullet('第 2 段：LEN=0A(10)，TYPE=09（完整设备名），VALUE 是 9 个字节：54 45 53 54 2D 44 45 56 49 43 45 → 查 ASCII 表 = "TEST-DEVICE"。'),
      _p('所以这台设备在手机上就显示为 TEST-DEVICE。广播数据页的"翻译视图"就是帮你做这一步：能翻译成字符的字节用绿色显示，翻译不了（如 FF）保持黑色十六进制。'),
      _h1('广播类型与间隔'),
      _bullet('ADV_IND：最普通广播，可连接（绝大多数设备）。'),
      _bullet('ADV_NONCONN_IND：只广播不让人连（如信标）。'),
      _bullet('ADV_SCAN_IND：可被扫描回应但不可连接。'),
      _bullet('广播间隔越短，越容易被扫到，但越费电；经典值 100ms~1s。'),
      _h1('调试提示'),
      _bullet('扫描列表里 RSSI 曲线抖动大是正常现象，2.4G 环境反射干扰所致，重点看趋势。'),
      _bullet('设备连上之后广播会停止，所以广播数据页只能看"未连接"状态的数据。'),
      _bullet('厂商自定义数据（0xFF）的格式各厂不同，需要对照自家固件协议文档解析。'),
    ];
  }
}
