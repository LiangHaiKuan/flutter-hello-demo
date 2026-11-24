import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'pages/scan_page.dart';

void main() {
  runApp(const BleToolApp());
}

class BleToolApp extends StatelessWidget {
  const BleToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE调试助手',
      debugShowCheckedModeBanner: false,
      // 中文本地化：长按文本的选择菜单（复制/粘贴/全选）显示中文
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF57C00),
          primary: const Color(0xFFF57C00),
        ),
        scaffoldBackgroundColor: const Color(0xFFF2F2F2),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF57C00),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? const Color(0xFFF57C00)
                : Colors.transparent,
          ),
          side: const BorderSide(color: Colors.grey, width: 2),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? const Color(0xFFF57C00)
                : Colors.grey,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? const Color(0xFFF57C00).withAlpha(80)
                : Colors.grey.withAlpha(60),
          ),
        ),
      ),
      home: const ScanPage(),
    );
  }
}
