import 'package:flutter/material.dart';

/// The 12 preset keys from app.js's WALLPAPER_PRESETS (server-whitelisted in
/// routes/conversations.py's WALLPAPER_KEYS) -- approximated here as simple
/// two-stop gradients rather than porting the exact multi-layer radial CSS,
/// since a mobile background only needs to read as "that same named mood",
/// not pixel-match the web version.
const Map<String, List<Color>> kWallpaperPresets = {
  'dawn': [Color(0xFF2B2C54), Color(0xFF1A1B2E)],
  'sunset': [Color(0xFF3A2340), Color(0xFF1A1B2E)],
  'forest': [Color(0xFF123A34), Color(0xFF1A1B2E)],
  'ocean': [Color(0xFF123048), Color(0xFF1A1B2E)],
  'rose': [Color(0xFF3A1D2E), Color(0xFF1A1B2E)],
  'slate': [Color(0xFF2A2A35), Color(0xFF1A1B2E)],
  'midnight': [Color(0xFF0F1226), Color(0xFF05060F)],
  'peach': [Color(0xFF3D2B2A), Color(0xFF1A1B2E)],
  'mint': [Color(0xFF123A3A), Color(0xFF1A1B2E)],
  'lavender': [Color(0xFF2E2A50), Color(0xFF1A1B2E)],
  'amber': [Color(0xFF3A2E12), Color(0xFF1A1B2E)],
  'coral': [Color(0xFF3A1F22), Color(0xFF1A1B2E)],
};

const Map<String, String> kWallpaperLabels = {
  'dawn': 'Dawn',
  'sunset': 'Sunset',
  'forest': 'Forest',
  'ocean': 'Ocean',
  'rose': 'Rose',
  'slate': 'Slate',
  'midnight': 'Midnight',
  'peach': 'Peach',
  'mint': 'Mint',
  'lavender': 'Lavender',
  'amber': 'Amber',
  'coral': 'Coral',
};

const Map<String, String> kWallpaperFitLabels = {
  'cover': 'Cover',
  'contain': 'Fit',
  'fill': 'Stretch',
  'tile': 'Tile',
};
