import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/session.dart';
import '../../theme.dart';

class ThemeSettingsScreen extends ConsumerWidget {
  const ThemeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final appearance = session.user?.appearance ?? const {};
    final palette = appearance['palette'] as String? ?? kDefaultPalette;
    final mode = appearance['mode'] as String? ?? 'dark';
    final structure = appearance['structure'] as String? ?? 'floating';
    final lightDisabled = kLightIncapablePalettes.contains(palette);

    return Scaffold(
      appBar: AppBar(title: const Text('Theme')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Palette', style: TextStyle(color: VeyonColors.muted, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.2,
            children: kPalettes.entries.map((entry) {
              final selected = entry.key == palette;
              final p = entry.value;
              return InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => ref.read(sessionControllerProvider.notifier).updateAppearance(palette: entry.key),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    gradient: p.bubbleGradient,
                    borderRadius: BorderRadius.circular(14),
                    border: selected ? Border.all(color: Colors.white, width: 2) : null,
                  ),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Text(p.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 28),
          const Text('Mode', style: TextStyle(color: VeyonColors.muted, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'dark', label: Text('Dark')),
              ButtonSegment(value: 'light', label: Text('Light')),
            ],
            selected: {lightDisabled ? 'dark' : mode},
            onSelectionChanged: lightDisabled
                ? null
                : (s) => ref.read(sessionControllerProvider.notifier).updateAppearance(mode: s.first),
          ),
          if (lightDisabled)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('This palette is dark-only.', style: TextStyle(color: VeyonColors.muted, fontSize: 12)),
            ),
          const SizedBox(height: 28),
          const Text('Chat bubble layout', style: TextStyle(color: VeyonColors.muted, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'floating', label: Text('Floating')),
              ButtonSegment(value: 'boxed', label: Text('Boxed')),
            ],
            selected: {structure},
            onSelectionChanged: (s) => ref.read(sessionControllerProvider.notifier).updateAppearance(structure: s.first),
          ),
        ],
      ),
    );
  }
}
