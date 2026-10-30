import 'package:flutter/material.dart';

import '../session.dart';
import '../realtime.dart';
import '../updates.dart';
import 'auth.dart';
import 'workspace.dart';
import 'realtime_scope.dart';
import 'update_page.dart';

class FruitVisionApp extends StatefulWidget {
  const FruitVisionApp({
    super.key,
    required this.controller,
    this.realtimeConnector,
    this.updates,
  });
  final SessionController controller;
  final HubConnector? realtimeConnector;
  final UpdateController? updates;
  @override
  State<FruitVisionApp> createState() => _FruitVisionAppState();
}

class _FruitVisionAppState extends State<FruitVisionApp>
    with WidgetsBindingObserver {
  late final RealtimeClient _hub;
  late final UpdateController _updates;
  bool _resumed = true;
  SessionController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    _updates = widget.updates ?? createUpdateController();
    _hub = RealtimeClient(
      api: controller.api,
      connector: widget.realtimeConnector,
    );
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_syncRealtime);
    _syncRealtime();
  }

  void _syncRealtime() {
    if (!controller.loading) _updates.setServer(controller.api.baseUrl);
    final user = controller.user;
    if (_resumed &&
        !controller.endingSession &&
        user != null &&
        user.isApproved) {
      _hub.start('${controller.api.baseUrl}:${user.id}');
    } else {
      _hub.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _syncRealtime();
  }

  @override
  void dispose() {
    controller.removeListener(_syncRealtime);
    WidgetsBinding.instance.removeObserver(this);
    _hub.dispose();
    if (widget.updates == null) _updates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => RealtimeScope(
      client: _hub,
      child: UpdateScope(
        updater: _updates,
        child: MaterialApp(
          key: ValueKey(
            '${controller.api.baseUrl}:${controller.user?.id ?? 'signed-out'}',
          ),
          title: 'FruitVision',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF146347),
              primary: const Color(0xFF146347),
              secondary: const Color(0xFF2C5F83),
              surface: Colors.white,
            ),
            scaffoldBackgroundColor: const Color(0xFFF5F8F5),
            cardTheme: CardThemeData(
              color: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: Color(0xFFE0E8E5)),
              ),
            ),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFF5F8F5),
              foregroundColor: Color(0xFF17352A),
              centerTitle: false,
              titleTextStyle: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Color(0xFF17352A),
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: Colors.white,
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                minimumSize: const Size(48, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          ),
          home: controller.loading
              ? const Scaffold(
                  body: SafeArea(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Đang mở phiên làm việc…'),
                        ],
                      ),
                    ),
                  ),
                )
              : UpdateStartupGate(
                  updater: _updates,
                  baseUrl: controller.api.baseUrl,
                  child: controller.signedIn
                      ? Workspace(
                          key: ValueKey(
                            '${controller.api.baseUrl}:${controller.user?.id}',
                          ),
                          controller: controller,
                        )
                      : AuthPage(controller: controller),
                ),
        ),
      ),
    ),
  );
}
