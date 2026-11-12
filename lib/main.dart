import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const HelloApp());
}

class HelloApp extends StatelessWidget {
  const HelloApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '你好Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _heartbeat = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 启动日志：手机连电脑后运行 `adb logcat -s flutter` 即可看到这一行
    debugPrint('=== 你好Demo 启动成功 ===');
    debugPrint('build mode: ${kDebugMode ? "debug" : "release"}');
    // 每秒打印一次心跳，用来验证"日志能实时回传到电脑"这条链路
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => _heartbeat++);
      debugPrint('心跳 $_heartbeat 次，运行中...');
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('你好Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.waving_hand, size: 72, color: Colors.orange),
            const SizedBox(height: 24),
            const Text(
              '欢迎使用',
              style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              '心跳：$_heartbeat 次',
              style: const TextStyle(fontSize: 18, color: Colors.grey),
            ),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: () {
                debugPrint('>>> 按钮被点击了，时间：${DateTime.now()}');
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已打印一条日志，去电脑上看')),
                );
              },
              child: const Text('点我打印日志'),
            ),
          ],
        ),
      ),
    );
  }
}
