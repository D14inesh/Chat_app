/// Business profile — category, description, address, hours, email and
/// website on your profile, shown to people in Contact info. Same fields
/// and wording as the website's Edit profile → Business profile.
library business_profile;

import '../../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/session.dart';
import 'shop.dart';

const kBusinessCategories = [
  'Jewellery', 'Finance & loans', 'Retail shop', 'Restaurant & food', 'Grocery', 'Clothing & fashion',
  'Beauty & salon', 'Health & medical', 'Education', 'Professional services', 'Automotive',
  'Real estate', 'Travel', 'Electronics', 'Other',
];

/// The "Business profile" section of Edit profile.
class BusinessEditor extends ConsumerStatefulWidget {
  const BusinessEditor({super.key});
  @override
  ConsumerState<BusinessEditor> createState() => _BusinessEditorState();
}

class _BusinessEditorState extends ConsumerState<BusinessEditor> {
  late final Map<String, dynamic> _b = Map<String, dynamic>.from(ref.read(sessionControllerProvider).user?.businessSettings ?? const {});
  late bool _enabled = _b['enabled'] == true;
  late String? _category = kBusinessCategories.contains(_b['category']) ? _b['category'] as String : null;
  late final _description = TextEditingController(text: _b['description'] as String? ?? '');
  late final _address = TextEditingController(text: _b['address'] as String? ?? '');
  late final _hours = TextEditingController(text: _b['hours'] as String? ?? '');
  late final _email = TextEditingController(text: _b['email'] as String? ?? '');
  late final _website = TextEditingController(text: _b['website'] as String? ?? '');
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_description, _address, _hours, _email, _website]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(sessionControllerProvider.notifier).updateBusiness({
        'enabled': _enabled,
        'category': _category ?? '',
        'description': _description.text.trim(),
        'address': _address.text.trim(),
        'hours': _hours.text.trim(),
        'email': _email.text.trim(),
        'website': _website.text.trim(),
      });
      messenger.showSnackBar(SnackBar(content: Text(_enabled ? 'Business profile saved.' : 'Business profile hidden.')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not save — check your connection.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
              secondary: Icon(Icons.storefront_rounded, color: Theme.of(context).colorScheme.secondary),
              title: const Text('Business profile', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Your hours, address and contact details on your profile'),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 220),
              crossFadeState: _enabled ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: _category,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: [for (final c in kBusinessCategories) DropdownMenuItem(value: c, child: Text(c))],
                      onChanged: (v) => setState(() => _category = v),
                    ),
                    const SizedBox(height: 10),
                    TextField(controller: _hours, maxLength: 120, decoration: const InputDecoration(labelText: 'Business hours', hintText: 'Mon–Sat, 9 am – 6 pm', counterText: '')),
                    const SizedBox(height: 10),
                    TextField(controller: _description, maxLength: 300, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Description', hintText: 'What you offer, in a line or two')),
                    TextField(controller: _address, maxLength: 200, decoration: const InputDecoration(labelText: 'Address', hintText: 'Shop no., street, city', counterText: '')),
                    const SizedBox(height: 10),
                    TextField(controller: _email, maxLength: 120, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email', hintText: 'hello@yourshop.com', counterText: '')),
                    const SizedBox(height: 10),
                    TextField(controller: _website, maxLength: 200, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Website', hintText: 'yourshop.com', counterText: '')),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save business profile')),
            ),
            if (ref.watch(sessionControllerProvider).user?.businessSettings?['enabled'] == true) ...[
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.shopping_bag_outlined),
                title: const Text('Catalogue'),
                subtitle: const Text('Products customers can browse and ask about', style: TextStyle(color: VeyonColors.muted)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CatalogManagerScreen())),
              ),
              ListTile(
                leading: const Icon(Icons.schedule_rounded),
                title: const Text('Away message'),
                subtitle: const Text('An automatic reply when you’re closed', style: TextStyle(color: VeyonColors.muted)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AwaySettingsScreen())),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shown in Contact info when the person has a business profile.
class BusinessInfoCard extends ConsumerStatefulWidget {
  final String userId;
  const BusinessInfoCard({super.key, required this.userId});
  @override
  ConsumerState<BusinessInfoCard> createState() => _BusinessInfoCardState();
}

class _BusinessInfoCardState extends ConsumerState<BusinessInfoCard> {
  // Fetched once — the screen around it rebuilds often (presence, etc.).
  late final Future<Map<String, dynamic>> _user = ref.read(sessionControllerProvider).api.getUser(widget.userId);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _user,
      builder: (context, snap) {
        final b = snap.data?['business'] as Map<String, dynamic>?;
        if (b == null) return const SizedBox.shrink();
        final accent = Theme.of(context).colorScheme.secondary;
        Widget row(IconData icon, String text, {VoidCallback? onTap}) => ListTile(
              dense: true,
              leading: Icon(icon, color: accent, size: 20),
              title: Text(text, style: TextStyle(fontSize: 14, decoration: onTap != null ? TextDecoration.underline : null)),
              onTap: onTap,
            );
        final category = (b['category'] as String?) ?? '';
        final website = (b['website'] as String?) ?? '';
        return Card(
          margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Chip(
                    avatar: Icon(Icons.storefront_rounded, size: 16, color: accent),
                    label: Text(category.isEmpty ? 'Business' : 'Business · $category', style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
                    side: BorderSide.none,
                    backgroundColor: accent.withValues(alpha: 0.14),
                  ),
                ),
                if ((b['description'] as String? ?? '').isNotEmpty)
                  Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 6), child: Text(b['description'] as String)),
                if ((b['address'] as String? ?? '').isNotEmpty)
                  row(Icons.location_on_outlined, b['address'] as String,
                      onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/search?query=${Uri.encodeComponent(b['address'] as String)}'),
                          mode: LaunchMode.externalApplication)),
                if ((b['hours'] as String? ?? '').isNotEmpty) row(Icons.schedule_rounded, b['hours'] as String),
                if ((b['email'] as String? ?? '').isNotEmpty)
                  row(Icons.mail_outline_rounded, b['email'] as String, onTap: () => launchUrl(Uri(scheme: 'mailto', path: b['email'] as String))),
                if (website.isNotEmpty)
                  row(Icons.link_rounded, website.replaceFirst(RegExp(r'^https?://'), ''),
                      onTap: () => launchUrl(Uri.parse(website), mode: LaunchMode.externalApplication)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.shopping_bag_outlined, size: 18),
                      label: const Text('View catalogue'),
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CatalogueScreen(userId: widget.userId, name: snap.data?['displayName'] as String?),
                      )),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
