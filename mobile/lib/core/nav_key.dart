import 'package:flutter/material.dart';

/// Lets code outside the widget tree (StateNotifiers reacting to a WS frame,
/// not a button press) push a screen -- used so an accepted live-game
/// invite can open its board immediately, the same way CallOverlay
/// interrupts the current screen for an incoming call.
final veyonNavigatorKey = GlobalKey<NavigatorState>();
