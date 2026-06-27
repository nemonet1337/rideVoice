import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'state/app_state_machine.dart';
import 'ui/home_screen.dart';

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });

  runApp(const RideVoiceApp());
}

class RideVoiceApp extends StatelessWidget {
  const RideVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'rideVoice',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(stateMachine: AppStateMachine()),
    );
  }
}
