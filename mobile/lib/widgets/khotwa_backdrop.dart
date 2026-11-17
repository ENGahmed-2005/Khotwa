import 'package:flutter/material.dart';

import '../core/khotwa_theme.dart';

/// Bundled decorative artwork: no network requests or student photographs.
abstract final class KhotwaArtwork {
  static const room = 'assets/backgrounds/learning-room.webp';
  static const desk = 'assets/backgrounds/learning-desk.webp';
}

class KhotwaBackdrop extends StatelessWidget {
  const KhotwaBackdrop({super.key, required this.child, this.welcome = false});

  final Widget child;
  final bool welcome;

  @override
  Widget build(BuildContext context) {
    final subdued =
        MediaQuery.highContrastOf(context) ||
        MediaQuery.textScalerOf(context).scale(14) >= 22;
    final wash = subdued
        ? const [Color(0xFAF8F5EF), Color(0xFAF8F5EF), Color(0xFAF8F5EF)]
        : welcome
        ? const [Color(0xC7F8F5EF), Color(0xEBF8F5EF), Color(0xE8F8F5EF)]
        : const [Color(0xE8F8F5EF), Color(0xF5F8F5EF), Color(0xE8F8F5EF)];
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: Image.asset(
                KhotwaArtwork.room,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                cacheWidth: 960,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: KhotwaPalette.cream),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: wash,
                  stops: const [0, .52, 1],
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class KhotwaPhotoPanel extends StatelessWidget {
  const KhotwaPhotoPanel({
    super.key,
    required this.child,
    this.minHeight = 176,
    this.padding = const EdgeInsets.all(22),
  });

  final Widget child;
  final double minHeight;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final strong =
        MediaQuery.highContrastOf(context) ||
        MediaQuery.textScalerOf(context).scale(14) >= 22;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: KhotwaPalette.navy.withValues(alpha: .12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: Image.asset(
                    KhotwaArtwork.desk,
                    fit: BoxFit.cover,
                    alignment: Alignment.centerLeft,
                    cacheWidth: 1280,
                    excludeFromSemantics: true,
                    errorBuilder: (_, _, _) =>
                        const ColoredBox(color: KhotwaPalette.navy),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      // Arabic copy starts on the right; the image remains
                      // visible to the left. Both ends support white text.
                      begin: Alignment.centerRight,
                      end: Alignment.centerLeft,
                      colors: strong
                          ? const [Color(0xFC17375E), Color(0xED17375E)]
                          : const [
                              Color(0xFA17375E),
                              Color(0xE017375E),
                              Color(0xB817375E),
                            ],
                    ),
                  ),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Padding(padding: padding, child: child),
            ),
          ],
        ),
      ),
    );
  }
}
