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
    final slice = context.slice;
    final color = !signed
        ? slice.ink
        : cents > 0
        ? slice.positive
        : cents < 0
        ? slice.negative
        : slice.settled;
    final text = signed ? formatSignedMoney(cents, currency) : formatMoney(cents, currency);
    // The sign is carried by colour (green/coral) and a +/− glyph. Neither
    // reaches a screen reader, and colour alone fails anyone who cannot
    // tell the two apart — so the direction is stated in words. Zero is
    // neither owed nor owing, so it stays plain.
    return Semantics(
      label: signed && cents != 0
          ? '${formatMoney(cents.abs(), currency)} ${cents > 0 ? 'owed to you' : 'you owe'}'
          : formatMoney(cents, currency),
      excludeSemantics: true,
      child: Text(
        text,
        style: moneyStyle(size: size, weight: weight, color: color),
      ),
    );
  }
}
