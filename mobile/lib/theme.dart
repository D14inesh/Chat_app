import 'package:flutter/material.dart';

/// One entry per palette in routes/users.py's APPEARANCE_OPTIONS /
/// the website's `[data-palette=...]` blocks. bubbleMe/bubbleMe2 is each
/// palette's accent pair (used as the Material seed and for accent
/// gradients); bg/panel are the dark-mode surfaces.
class PaletteColors {
  final String label;
  final Color bubbleMe;
  final Color bubbleMe2;
  final Color bgDark;
  final Color panelDark;
  final Color online;
  const PaletteColors({
    required this.label,
    required this.bubbleMe,
    required this.bubbleMe2,
    required this.bgDark,
    required this.panelDark,
    required this.online,
  });

  LinearGradient get bubbleGradient =>
      LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [bubbleMe, bubbleMe2]);
}

const Map<String, PaletteColors> kPalettes = {
  // The calm default, matching the website: warm stone neutrals, soft indigo.
  'veyon': PaletteColors(
    label: 'Veyon',
    bubbleMe: Color(0xFF4263EB),
    bubbleMe2: Color(0xFF5C7CFA),
    bgDark: Color(0xFF0E0F11),
    panelDark: Color(0xFF17181B),
    online: Color(0xFF12B886),
  ),
  'aurora': PaletteColors(
    label: 'Aurora',
    bubbleMe: Color(0xFF7C5CFF),
    bubbleMe2: Color(0xFF22D3EE),
    bgDark: Color(0xFF08090F),
    panelDark: Color(0xFF16172E),
    online: Color(0xFF2EE6A6),
  ),
  'obsidian': PaletteColors(
    label: 'Obsidian & Gold',
    bubbleMe: Color(0xFFE8C77B),
    bubbleMe2: Color(0xFFC9A55E),
    bgDark: Color(0xFF0A0A0B),
    panelDark: Color(0xFF141416),
    online: Color(0xFF8FB98A),
  ),
  'nord': PaletteColors(
    label: 'Nord Frost',
    bubbleMe: Color(0xFF5E81AC),
    bubbleMe2: Color(0xFF88C0D0),
    bgDark: Color(0xFF2E3440),
    panelDark: Color(0xFF333A47),
    online: Color(0xFFA3BE8C),
  ),
  'cyber': PaletteColors(
    label: 'Neon Cyberpunk',
    bubbleMe: Color(0xFFFF2E97),
    bubbleMe2: Color(0xFF00F0FF),
    bgDark: Color(0xFF05060A),
    panelDark: Color(0xFF0C0F18),
    online: Color(0xFF00F0FF),
  ),
  'plum': PaletteColors(
    label: 'Sugar Plum',
    bubbleMe: Color(0xFFA76BC9),
    bubbleMe2: Color(0xFFD68FC0),
    bgDark: Color(0xFF211A30),
    panelDark: Color(0xFF2A2140),
    online: Color(0xFF7EE8C0),
  ),
};

const kDefaultPalette = 'veyon';
// 'cyber' is dark-only on web too (routes/users.py forces mode='dark' for it).
const kLightIncapablePalettes = {'cyber'};

/// Fixed brand colours for widgets that don't read the active palette.
class VeyonColors {
  static const bubbleMe = Color(0xFF4263EB);
  static const bubbleMe2 = Color(0xFF5C7CFA);
  static const bgDark = Color(0xFF0E0F11);
  static const bgLight = Color(0xFFF7F6F3);
  static const online = Color(0xFF12B886);
  static const danger = Color(0xFFE5484D);

  /// Other people's bubbles in dark mode (light mode uses white).
  static const bubbleThemDark = Color(0xFF25272C);

  /// Dark text on light surfaces (bubbles, cards).
  static const inkLight = Color(0xFF1C1B19);

  /// Secondary text that reads on both light and dark backgrounds.
  static const muted = Color(0xFF8E8C93);

  /// Hairline dividers / faint fills, and slightly stronger borders.
  static const hairline = Color(0x1F8E8C93);
  static const line = Color(0x4D8E8C93);

  static const bubbleGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [bubbleMe2, bubbleMe],
  );

  /// The ring around someone's avatar while they have a status you haven't seen.
  static const statusRing = SweepGradient(
    colors: [Color(0xFF4C6EF5), Color(0xFF12B886), Color(0xFF22B8CF), Color(0xFF4C6EF5)],
  );
}

PaletteColors paletteColors(String? palette) => kPalettes[palette] ?? kPalettes[kDefaultPalette]!;

ThemeData veyonTheme({String palette = kDefaultPalette, String mode = 'dark'}) {
  final p = paletteColors(palette);
  final isDark = mode != 'light' || kLightIncapablePalettes.contains(palette);
  final calm = palette == kDefaultPalette;

  final bg = isDark ? p.bgDark : (calm ? VeyonColors.bgLight : const Color(0xFFF2F6FF));
  final surface = isDark ? p.panelDark : Colors.white;
  final raised = isDark ? Color.lerp(p.panelDark, Colors.white, 0.05)! : Colors.white;
  final field = isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFEFEEEA);
  final text = isDark ? const Color(0xFFECECEE) : VeyonColors.inkLight;
  final onAccent = palette == 'obsidian' ? const Color(0xFF1A1400) : Colors.white;
  final accentText = isDark ? p.bubbleMe2 : p.bubbleMe;

  final scheme = ColorScheme.fromSeed(
    seedColor: p.bubbleMe,
    brightness: isDark ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: p.bubbleMe,
    onPrimary: onAccent,
    secondary: p.bubbleMe2,
    surface: surface,
    onSurface: text,
    onSurfaceVariant: VeyonColors.muted,
    surfaceContainerLowest: bg,
    surfaceContainerLow: surface,
    surfaceContainer: raised,
    surfaceContainerHigh: raised,
    surfaceContainerHighest: field,
    outline: VeyonColors.line,
    outlineVariant: VeyonColors.hairline,
    error: VeyonColors.danger,
    surfaceTint: Colors.transparent,
  );

  const pill = StadiumBorder();
  final soft = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  final accentWash = p.bubbleMe.withValues(alpha: isDark ? 0.22 : 0.12);
  OutlineInputBorder fieldBorder([BorderSide side = BorderSide.none]) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: side);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    dividerColor: VeyonColors.hairline,
    splashFactory: InkSparkle.splashFactory,

    textTheme: Typography.material2021(platform: TargetPlatform.android)
        .englishLike
        .merge(isDark ? Typography.material2021().white : Typography.material2021().black)
        .apply(bodyColor: text, displayColor: text)
        .copyWith(
          titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.4, color: text),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.1, color: text),
          bodyMedium: TextStyle(fontSize: 14.5, height: 1.35, color: text),
          bodySmall: const TextStyle(fontSize: 12.5, color: VeyonColors.muted),
        ),

    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: text),
      iconTheme: IconThemeData(color: text.withValues(alpha: 0.85), size: 23),
      actionsIconTheme: IconThemeData(color: text.withValues(alpha: 0.85), size: 23),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 68,
      indicatorColor: accentWash,
      indicatorShape: pill,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: s.contains(WidgetState.selected) ? text : VeyonColors.muted,
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            size: 24,
            color: s.contains(WidgetState.selected) ? accentText : VeyonColors.muted,
          )),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: field,
      hintStyle: const TextStyle(color: VeyonColors.muted),
      labelStyle: const TextStyle(color: VeyonColors.muted),
      floatingLabelStyle: TextStyle(color: accentText, fontWeight: FontWeight.w600),
      prefixIconColor: VeyonColors.muted,
      suffixIconColor: VeyonColors.muted,
      border: fieldBorder(),
      enabledBorder: fieldBorder(),
      focusedBorder: fieldBorder(BorderSide(color: p.bubbleMe.withValues(alpha: 0.7), width: 1.4)),
      errorBorder: fieldBorder(const BorderSide(color: VeyonColors.danger, width: 1.2)),
      focusedErrorBorder: fieldBorder(const BorderSide(color: VeyonColors.danger, width: 1.4)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.bubbleMe,
        foregroundColor: onAccent,
        shape: pill,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.bubbleMe,
        foregroundColor: onAccent,
        elevation: 0,
        shape: pill,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        shape: pill,
        side: const BorderSide(color: VeyonColors.line),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accentText,
        shape: pill,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.bubbleMe,
      foregroundColor: onAccent,
      elevation: 1,
      focusElevation: 1,
      hoverElevation: 2,
      highlightElevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),

    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: raised,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      titleTextStyle: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: text),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: raised,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: raised,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: raised,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: soft,
      textStyle: TextStyle(fontSize: 14.5, color: text),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: VeyonColors.muted,
      textColor: text,
      subtitleTextStyle: const TextStyle(fontSize: 13, color: VeyonColors.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: field,
      selectedColor: accentWash,
      disabledColor: field,
      side: BorderSide.none,
      shape: pill,
      showCheckmark: false,
      labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: text),
      secondaryLabelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: accentText),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isDark ? const Color(0xFF2A2B30) : VeyonColors.inkLight,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      actionTextColor: p.bubbleMe2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 2,
    ),
    dividerTheme: const DividerThemeData(color: VeyonColors.hairline, thickness: 0.8, space: 1),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.bubbleMe : null),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.bubbleMe : null),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: text,
      unselectedLabelColor: VeyonColors.muted,
      indicatorColor: p.bubbleMe,
      dividerColor: VeyonColors.hairline,
      labelStyle: const TextStyle(fontWeight: FontWeight.w700),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.bubbleMe),
    badgeTheme: BadgeThemeData(backgroundColor: p.bubbleMe, textColor: onAccent),
  );
}

/// Back-compat for any leftover call sites; equivalent to veyonTheme().
ThemeData veyonDarkTheme() => veyonTheme();
