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
      _bullet('发送目标：本 App 发送栏发出的数据走哪个特征值，取决于你选的"发送目标"（蓝牙服务页点击上传图标点亮，或发送栏"未选特征"按钮选择）。'),
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
      _p('广播信道固定用 3 个"跳频保护"信道：37 (2402MHz)、38 (2426MHz)、39 (2480MHz)，刻意避开 Wi-Fi 最常用的信道，减少同频干扰。'),

      _h1('两种包：广播包 + 扫描回应包'),
      _bullet('ADV（广播包）：最多 31 字节，设备周期性发出，人人都能收到。'),
      _bullet('SCAN_RSP（扫描回应包）：另外最多 31 字节，手机主动发 SCAN_REQ 后设备才回。名字太长放不下的设备，通常把完整名字放在扫描回应包里。'),
      _bullet('总共可用 62 字节；BLE 5 的扩展广播单包可到 255 字节、还能串联更大，但安卓旧接口一般只暴露传统 31 字节。'),

      _h1('广播包的结构：一串 LEN/TYPE/VALUE'),
      _p('广播数据由若干个"AD 结构"（AD Structure）首尾拼接而成，每个结构的格式都是三段：'),
      _code('01 06 03 0A 00 09 09 33 37 39 33 32 31 39\n|\\  |  |   |  |  |  \\_______ VALUE _______/\n|   | |   | |  |  \\_ TYPE=0x09 完整设备名\n|   | |   | |  \\_ LEN=9（TYPE+VALUE 共 9 字节）\n|   | |   | \\_ TYPE=0x0A 发射功率\n|   | |   \\_ LEN=3\n|   | \\_ VALUE=0x06\n|   \\_ TYPE=0x01 Flags\n\\_ LEN=2'),
      _bullet('LEN（1字节）：后面 TYPE + VALUE 一共多少字节（不含 LEN 自己）。'),
      _bullet('TYPE（1字节）：这段数据是什么类型，由蓝牙联盟（Bluetooth SIG）统一编号。'),
      _bullet('VALUE（LEN-1 字节）：实际数据。'),

      _h1('Flags（TYPE=0x01）逐位含义'),
      _p('Flags 只有 1 字节 VALUE，每一位都有明确规定：'),
      _table([
        ['位', '含义'],
        ['bit0', 'LE 有限可发现（Limited Discoverable）'],
        ['bit1', 'LE 通用可发现（General Discoverable，常置 1）'],
        ['bit2', '不支持 BR/EDR（经典蓝牙）—— 纯 BLE 设备置 1'],
        ['bit3', '同时支持 BR/EDR + LE（双模设备）'],
        ['bit5~7', '控制器/主机组合的双模标志（手机、耳机用）'],
      ], flex: [2, 9]),
      _bullet('常见值 0x06 = bit1+bit2：纯 BLE、可连接、通用可发现 —— 99% 的 BLE 设备用它。'),
      _bullet('0x0A = bit1+bit3：双模设备（手机、耳机等经典蓝牙+BLE）。'),

      _h1('蓝牙联盟 AD TYPE 对照表'),
      _p('下面是 SIG《Assigned Numbers》里常用的广播类型编号：'),
      _table([
        ['TYPE', '名称', 'VALUE 含义'],
        ['0x01', 'Flags', '设备模式标志（见上表）'],
        ['0x02', '不完整 16 位服务 UUID 列表', '服务太多放不下，只放一部分'],
        ['0x03', '完整 16 位服务 UUID 列表', '16 位短 UUID（如 FFE0、180F）'],
        ['0x04/0x05', '32 位服务 UUID 列表', '少见'],
        ['0x06', '不完整 128 位服务 UUID 列表', '自定义服务（如 Nordic UART）'],
        ['0x07', '完整 128 位服务 UUID 列表', '自定义服务的完整 UUID'],
        ['0x08', '短本地名称', '设备名截短版'],
        ['0x09', '完整本地名称', '扫描列表显示的名字（ASCII/UTF-8）'],
        ['0x0A', '发射功率 Tx Power', '1 字节有符号数，单位 dBm，如 0x00=0dBm、0xF4=-12dBm'],
        ['0x0D', 'Class of Device', '经典蓝牙设备类别'],
        ['0x12', '外设连接间隔范围', '建议的连接参数范围（4 字节）'],
        ['0x14/0x15', '服务请求数据', '希望连接某服务的请求 + 数据'],
        ['0x16', '服务数据 - 16 位 UUID', '某服务对外广播的数据'],
        ['0x19', 'Appearance 外观', '2 字节图标类别：0x0341=手环、0x03C2=鼠标等'],
        ['0x1C', '服务数据 - 128 位 UUID', '同 0x16，128 位版本'],
        ['0x21', '公开服务数据', 'Eddystone-URL 等用它（0xFEAA）'],
        ['0x24', 'URI', '广播一个 URI 链接'],
        ['0xFF', '厂商自定义数据', '前 2 字节厂商 ID（小端），后面格式厂商自定'],
      ], flex: [2, 4, 6]),

      _h1('厂商自定义数据（0xFF）详解'),
      _p('这是最灵活的类型：前 2 字节是蓝牙联盟分配的厂商 ID（小端存放），后面的内容格式厂商自己定。常见厂商 ID：'),
      _table([
        ['ID（字节序）', '厂商', '典型数据'],
        ['4C 00', 'Apple', 'iBeacon：02 15 + 16字节UUID + Major + Minor + 1米处RSSI'],
        ['75 00', 'Samsung', 'Find My Mobile 等'],
        ['06 D6', '小米', '米家设备心跳/认证数据'],
        ['E7 02', 'Google', 'Fast Pair 快速配对'],
        ['其他', '各家私有', '对照自家固件协议文档解析'],
      ], flex: [3, 3, 6]),
      _p('iBeacon 完整例子：4C 00 02 15 E2C56DB5-DFFB-48D2-B060-D0F5A71096E0 0001 0002 C5 → Apple 厂商数据，iBeacon 前缀，UUID=E2C56DB5...，Major=1，Minor=2，1米处信号强度=-59dBm。'),

      _h1('广播类型（PDU）与间隔'),
      _table([
        ['类型', '可连接', '可扫描回应', '典型用途'],
        ['ADV_IND', '✓', '✓', '最普通的广播，绝大多数设备'],
        ['ADV_DIRECT_IND', '✓(指定对象)', '✗', '定向回连旧主机'],
        ['ADV_SCAN_IND', '✗', '✓', '信标（Beacon），只让人扫不让人连'],
        ['ADV_NONCONN_IND', '✗', '✗', '纯数据广播'],
      ], flex: [3, 3, 3, 4]),
      _bullet('广播间隔：20ms ~ 10.24s。间隔越短越容易被扫到、越费电；常见 100ms~1.28s。'),
      _bullet('同一间隔里 3 个信道（37/38/39）各发一次，所以扫描器经常"连续收到 3 包几乎相同的数据"。'),

      _h1('手把手解析一个例子'),
      _p('假设原始广播数据是：'),
      _code('02 01 06 0A 09 54 45 53 54 2D 44 45 56 49 43 45'),
      _bullet('第 1 段：LEN=02，TYPE=01（Flags），VALUE=06 → 可连接的通用广播。'),
      _bullet('第 2 段：LEN=0A(10)，TYPE=09（完整设备名），VALUE 是 10 个字节：54 45 53 54 2D 44 45 56 49 43 45 → 查 ASCII 表 = "TEST-DEVICE"。'),
      _p('所以这台设备在手机上就显示为 TEST-DEVICE。广播数据页的"翻译视图"就是帮你做这一步：能翻译成字符的字节用绿色显示，翻译不了（如 FF）保持黑色十六进制。'),

      _h1('调试提示'),
      _bullet('扫描列表里 RSSI 曲线抖动大是正常现象，2.4G 环境反射干扰所致，重点看趋势。'),
      _bullet('设备连上之后广播会停止，所以广播数据页只能看"未连接"状态的数据。'),
      _bullet('广播数据经常缺字段（比如没有名字）→ 名字可能在扫描回应包里，或广播间隔太长还没等到。'),
      _bullet('同一台设备每次广播内容微变（如某个字节递增）→ 可能是计数器或电量，对照固件协议看。'),
      _bullet('厂商自定义数据（0xFF）的格式各厂不同，需要对照自家固件协议文档解析。'),
    ];
  }
}
