import 'package:flutter/material.dart';
import '../state/app_state_machine.dart';

class HomeScreen extends StatelessWidget {
  final AppStateMachine stateMachine;

  const HomeScreen({super.key, required this.stateMachine});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('rideVoice'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: StreamBuilder<AppState>(
        stream: stateMachine.states,
        initialData: stateMachine.current,
        builder: (context, snapshot) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'State: ${snapshot.data?.name ?? 'unknown'}',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 24),
                if (snapshot.data == AppState.idle)
                  ElevatedButton.icon(
                    onPressed: () => stateMachine.transition(AppState.discovering),
                    icon: const Icon(Icons.search),
                    label: const Text('Start Discovery'),
                  )
                else if (snapshot.data == AppState.discovering)
                  ElevatedButton.icon(
                    onPressed: () => stateMachine.transition(AppState.idle),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop Discovery'),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
