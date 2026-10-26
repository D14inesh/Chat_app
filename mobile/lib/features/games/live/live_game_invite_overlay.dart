import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'live_game_controller.dart';

/// A small top banner (not a full-screen takeover like CallOverlay) for the
/// two "waiting" phases of a live game invite -- once a game is actually
/// playing, LiveGameController pushes the game's own screen instead.
class LiveGameInviteOverlay extends ConsumerWidget {
  const LiveGameInviteOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final game = ref.watch(liveGameControllerProvider);
    if (game.phase != LiveGamePhase.inviteReceived && game.phase != LiveGamePhase.inviteSent) {
      return const SizedBox.shrink();
    }
    final controller = ref.read(liveGameControllerProvider.notifier);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Material(
          color: const Color(0xFF141A33),
          elevation: 8,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Text(liveGames[game.game]?.emoji ?? '🎮', style: const TextStyle(fontSize: 24)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        game.phase == LiveGamePhase.inviteReceived ? '${game.peerName} wants to play' : 'Waiting for ${game.peerName}…',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        game.phase == LiveGamePhase.inviteReceived ? _gameLabel(game.game) : '${_gameLabel(game.game)} invite sent',
                        style: const TextStyle(color: Colors.white60, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                if (game.phase == LiveGamePhase.inviteReceived) ...[
                  TextButton(onPressed: () => controller.respondToInvite(false), child: const Text('Decline')),
                  FilledButton(onPressed: () => controller.respondToInvite(true), child: const Text('Accept')),
                ] else
                  TextButton(onPressed: controller.leaveGame, child: const Text('Cancel')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _gameLabel(String game) => liveGames[game]?.label ?? game;
}
