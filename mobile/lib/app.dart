import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_lock_store.dart';
import 'core/branding.dart';
import 'core/app_visibility.dart';
import 'features/assistant/voice_assistant.dart';
import 'features/notifications/message_notifier.dart';
import 'core/nav_key.dart';
import 'features/applock/app_lock_screen.dart';
import 'features/auth/auth_screen.dart';
import 'features/auth/contact_fields.dart';
import 'features/auth/session.dart';
import 'features/auth/login_approval.dart';
import 'features/calls/call_screen.dart';
import 'features/home/home_shell.dart';
import 'features/effects/effects_overlay.dart';
import 'features/security/security_screen.dart';
import 'features/games/live/live_game_invite_overlay.dart';
import 'theme.dart';
import 'features/chat/voice_playback.dart';
import 'features/calls/calls_extras.dart';
import 'features/share/launch_handler.dart';

class VeyonApp extends ConsumerWidget {
  const VeyonApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apiAsync = ref.watch(apiClientProvider);
    final appearance = ref.watch(sessionControllerProvider.select((s) => s.user?.appearance));

    return MaterialApp(
      navigatorKey: veyonNavigatorKey,
      title: ref.watch(brandingProvider).valueOrNull?.name ?? 'Veyon Chat',
      debugShowCheckedModeBanner: false,
      theme: veyonTheme(
        palette: appearance?['palette'] as String? ?? kDefaultPalette,
        mode: appearance?['mode'] as String? ?? 'dark',
      ),
      home: apiAsync.when(
        loading: () => const _SplashScreen(),
        error: (e, _) => _SplashScreen(error: 'Could not reach the server: $e'),
        data: (_) => const _Gate(),
      ),
      // The call overlay is mounted at the app root (outside any one screen's
      // widget tree) so an incoming call can interrupt whatever is on screen,
      // the same way a phone call does -- see CallController's doc comment.
      // The live-game invite overlay is a lighter-weight banner, not a
      // full-screen takeover -- see LiveGameController's doc comment.
      builder: (context, child) => Stack(
        children: [
          if (child != null) child,
          const EffectsOverlay(),
          const CallOverlay(),
          const LiveGameInviteOverlay(),
          const VoiceAssistantBadge(),
          const LoginAlertOverlay(),
          const LoginApprovalListener(),
          const VoiceMiniPlayer(),
          const CallRinger(),
          const MissedCallsWatcher(),
          const LaunchHandler(),
        ],
      ),
    );
  }
}

/// Restores a previous session (the key and profile saved on this phone —
/// no network needed) before deciding which screen to show, so a returning
/// user goes straight to their chats until they log out.
class _Gate extends ConsumerStatefulWidget {
  const _Gate();

  @override
  ConsumerState<_Gate> createState() => _GateState();
}

class _GateState extends ConsumerState<_Gate> with WidgetsBindingObserver {
  bool _restoring = true;
  AppLockMethod _lockMethod = AppLockMethod.none;
  bool _unlocked = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the background: reconnect right away rather than
    // waiting for the next retry (Android often drops sockets of apps in
    // the background).
    AppVisibility.inForeground.value = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      ref.read(sessionControllerProvider.notifier).onAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.wait([
      ref.read(sessionControllerProvider.notifier).tryRestoreSession(),
      AppLockStore().getMethod().then((m) => _lockMethod = m),
    ]).whenComplete(() {
      if (mounted) setState(() => _restoring = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) return const _SplashScreen();
    final session = ref.watch(sessionControllerProvider);
    if (!session.isSignedIn) return const AuthScreen();
    ref.watch(messageNotifierProvider); // message & call notifications while signed in
    ref.watch(voiceAssistantProvider); // re-arms "Hey ARM" if it was on last time
    // The lock only ever guards an already-signed-in session -- it's a
    // privacy screen for someone picking up an unlocked phone, not an auth
    // mechanism, so it never blocks reaching the sign-in screen itself.
    if (_lockMethod != AppLockMethod.none && !_unlocked) {
      return AppLockScreen(method: _lockMethod, onUnlocked: () => setState(() => _unlocked = true));
    }
    // Older accounts add a mobile number + Gmail once before going on.
    if (session.user?.contactVerified == false) return const VerifyContactScreen(blocking: true);
    return const HomeShell();
  }
}

class _SplashScreen extends StatelessWidget {
  final String? error;
  const _SplashScreen({this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VeyonColors.bgDark,
      body: Center(
        child: error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Text(error!, style: const TextStyle(color: VeyonColors.muted), textAlign: TextAlign.center),
              ),
      ),
    );
  }
}
