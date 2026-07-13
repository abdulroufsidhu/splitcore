// 1e — Receipt viewer, dark surface per the design's alternate-theme card.
import 'package:flutter/material.dart';

import '../money.dart';
import '../theme.dart';

class ReceiptViewerScreen extends StatelessWidget {
  const ReceiptViewerScreen({
    super.key,
    required this.imageUrl,
    required this.description,
    required this.amountCents,
    required this.currency,
  });

  final String imageUrl;
  final String description;
  final int amountCents;
  final String currency;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF161513),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: SliceColors.paper),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          description,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: SliceColors.paper),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          formatMoney(amountCents, currency),
                          style: moneyStyle(size: 12, color: Colors.white.withValues(alpha: 0.65)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stack) => const Text(
                        '[ receipt photo unavailable ]',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
