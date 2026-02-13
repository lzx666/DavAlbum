// main.dart 完整代码
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pages/home_page.dart';

void main() {
  // 设置状态栏透明
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'TimeAlbum',
      // --- 核心设置开始 ---
      theme: ThemeData(
        useMaterial3: true, // ✅ 开启 Material 3
        // 设置一个种子颜色，Flutter 会根据这个颜色自动生成全套的和谐配色
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent, 
          brightness: Brightness.light, // 如果想做深色模式，改这里
        ),
      ),
      // --- 核心设置结束 ---
      home: const SuperBackupPage(),
    );
  }
}