// Cents + currency code -> display string. One helper, reused everywhere
// a Balance/Expense/Settlement amount is shown, so formatting never drifts
// between screens. No conversion logic — currency is a group-level label.
import 'package:intl/intl.dart';

const _symbols = {'USD': r'$', 'EUR': '€', 'GBP': '£'};

String currencySymbol(String currencyCode) => _symbols[currencyCode] ?? '$currencyCode ';

/// Formats [cents] as e.g. "$86.40" (unsigned) using [currencyCode]'s symbol.
String formatMoney(int cents, String currencyCode) {
  final format = NumberFormat.currency(symbol: currencySymbol(currencyCode), decimalDigits: 2);
  return format.format(cents.abs() / 100);
}

/// Formats [cents] signed, e.g. "+$62.10" / "-€38.20" — the home/balance style.
String formatSignedMoney(int cents, String currencyCode) {
  final sign = cents > 0 ? '+' : (cents < 0 ? '−' : '');
  return '$sign${formatMoney(cents, currencyCode)}';
}
