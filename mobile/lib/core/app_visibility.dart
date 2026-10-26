/// What the user is looking at right now — used to decide whether a new
/// message deserves a notification (not if its chat is already on screen).
library app_visibility;

import 'package:flutter/foundation.dart';

class AppVisibility {
  /// True while the app is in the foreground.
  static final inForeground = ValueNotifier<bool>(true);

  /// The chat currently open on screen, if any.
  static final openChatId = ValueNotifier<String?>(null);
}
