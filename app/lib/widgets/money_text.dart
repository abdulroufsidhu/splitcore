// The one reused money primitive: mono, signed, colored by state — the
// design's whole rule ("positive green, negative coral, settled gray")
// lives here so no screen re-derives it.
import 'package:flutter/material.dart';

import '../money.dart';
import '../theme.dart';

class MoneyText extends StatelessWidget {
  const MoneyText(
    this.cents,
    this.currency, {
    super.key,
    this.signed = true,
    this.size = 15,
    this.weight = FontWeight.w600,
  });

  final int cents;
  final String currency;
  final bool signed;
  final double size;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    final color = !signed
        ? SliceColors.ink
        : cents > 0
            ? SliceColors.positive
            : cents < 0
                ? SliceColors.negative
                : SliceColors.settled;
    final text = signed ? formatSignedMoney(cents, currency) : formatMoney(cents, currency);
    return Text(text, style: moneyStyle(size: size, weight: weight, color: color));
  }
}
