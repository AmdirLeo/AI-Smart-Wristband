import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'state/app_state.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  runApp(
    ChangeNotifierProvider.value(
      value: state,
      child: const YianApp(),
    ),
  );
  // 初始化（读配置、连云端）放在首帧之后，启动更快
  await state.init();
}

class YianApp extends StatelessWidget {
  const YianApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '颐安云护',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const HomeScreen(),
    );
  }
}
