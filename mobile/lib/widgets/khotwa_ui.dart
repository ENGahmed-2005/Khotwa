import 'package:flutter/material.dart';

import '../core/khotwa_theme.dart';

class KhotwaBrandMark extends StatelessWidget {
  const KhotwaBrandMark({super.key, this.size = 58});
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(size * .22),
      child: Image.asset(
        'assets/branding/khotwa-icon.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
      ),
    ),
  );
}

class KhotwaPageIntro extends StatelessWidget {
  const KhotwaPageIntro({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
  });
  final String title, description;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18, top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: KhotwaPalette.paleAmber,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: KhotwaPalette.navy, size: 27),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 5),
              Text(
                description,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: KhotwaPalette.muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class KhotwaSectionCard extends StatelessWidget {
  const KhotwaSectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 21),
                const SizedBox(width: 9),
              ],
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

class KhotwaEmptyState extends StatelessWidget {
  const KhotwaEmptyState({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
    this.action,
  });
  final String title, message;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: const BoxDecoration(
              color: KhotwaPalette.paleBlue,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: KhotwaPalette.navy, size: 35),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: KhotwaPalette.muted),
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}
