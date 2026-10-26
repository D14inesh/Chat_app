import 'package:flutter/material.dart';

/// The text colour inside a message bubble. Your own bubbles are a solid
/// accent, so their text is white; other people's bubbles follow light/dark
/// mode (white card with dark text in light mode). Set once per bubble in
/// chat_screen.dart; everything drawn inside reads it from here instead of
/// hard-coding white.
class BubbleInk extends InheritedWidget {
  final Color fg;
  const BubbleInk({super.key, required this.fg, required super.child});

  /// Main text colour (white outside any bubble, e.g. previews).
  static Color of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BubbleInk>()?.fg ?? Colors.white;

  /// Secondary text: times, sizes, captions.
  static Color dim(BuildContext context, [double alpha = 0.62]) => of(context).withValues(alpha: alpha);

  /// Links: light blue on a dark/accent bubble, the accent on a light one.
  static Color link(BuildContext context) =>
      of(context).computeLuminance() > 0.5 ? const Color(0xFFC5D5FF) : const Color(0xFF3B5BDB);

  /// Wraps [child] so plain Text and Icons inherit [fg] too.
  static Widget wrap({required Color fg, required Widget child}) => BubbleInk(
        fg: fg,
        child: DefaultTextStyle.merge(
          style: TextStyle(color: fg),
          child: IconTheme.merge(data: IconThemeData(color: fg), child: child),
        ),
      );

  @override
  bool updateShouldNotify(BubbleInk oldWidget) => oldWidget.fg != fg;
}
