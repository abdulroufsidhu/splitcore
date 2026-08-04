// Cents + currency code -> display string. One helper, reused everywhere
// a Balance/Expense/Settlement amount is shown, so formatting never drifts
// between screens. No conversion logic — currency is a group-level label.
import 'package:intl/intl.dart';

/// Symbol for an ISO 4217 code, via intl's built-in currency table (covers
/// every currency intl knows, not just a hand-picked few). Falls back to
/// the code itself for anything intl doesn't recognize.
String currencySymbol(String currencyCode) {
  try {
    return NumberFormat.simpleCurrency(name: currencyCode).currencySymbol;
  } catch (_) {
    return '$currencyCode ';
  }
}

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

/// ISO 4217 codes offered by the currency picker, with display names for
/// search. Not exhaustive of every ISO code that has ever existed — the
/// currencies actually in common use.
const isoCurrencies = <String, String>{
  'USD': 'US Dollar',
  'EUR': 'Euro',
  'GBP': 'British Pound',
  'JPY': 'Japanese Yen',
  'CNY': 'Chinese Yuan',
  'INR': 'Indian Rupee',
  'AUD': 'Australian Dollar',
  'CAD': 'Canadian Dollar',
  'CHF': 'Swiss Franc',
  'HKD': 'Hong Kong Dollar',
  'SGD': 'Singapore Dollar',
  'SEK': 'Swedish Krona',
  'NOK': 'Norwegian Krone',
  'DKK': 'Danish Krone',
  'NZD': 'New Zealand Dollar',
  'KRW': 'South Korean Won',
  'MXN': 'Mexican Peso',
  'BRL': 'Brazilian Real',
  'ZAR': 'South African Rand',
  'RUB': 'Russian Ruble',
  'TRY': 'Turkish Lira',
  'PLN': 'Polish Zloty',
  'THB': 'Thai Baht',
  'IDR': 'Indonesian Rupiah',
  'MYR': 'Malaysian Ringgit',
  'PHP': 'Philippine Peso',
  'VND': 'Vietnamese Dong',
  'ILS': 'Israeli Shekel',
  'AED': 'UAE Dirham',
  'SAR': 'Saudi Riyal',
  'QAR': 'Qatari Riyal',
  'KWD': 'Kuwaiti Dinar',
  'BHD': 'Bahraini Dinar',
  'OMR': 'Omani Rial',
  'EGP': 'Egyptian Pound',
  'NGN': 'Nigerian Naira',
  'KES': 'Kenyan Shilling',
  'GHS': 'Ghanaian Cedi',
  'PKR': 'Pakistani Rupee',
  'BDT': 'Bangladeshi Taka',
  'LKR': 'Sri Lankan Rupee',
  'NPR': 'Nepalese Rupee',
  'CZK': 'Czech Koruna',
  'HUF': 'Hungarian Forint',
  'RON': 'Romanian Leu',
  'BGN': 'Bulgarian Lev',
  'HRK': 'Croatian Kuna',
  'UAH': 'Ukrainian Hryvnia',
  'ISK': 'Icelandic Krona',
  'ARS': 'Argentine Peso',
  'CLP': 'Chilean Peso',
  'COP': 'Colombian Peso',
  'PEN': 'Peruvian Sol',
  'UYU': 'Uruguayan Peso',
  'BOB': 'Bolivian Boliviano',
  'PYG': 'Paraguayan Guarani',
  'CRC': 'Costa Rican Colon',
  'DOP': 'Dominican Peso',
  'GTQ': 'Guatemalan Quetzal',
  'JMD': 'Jamaican Dollar',
  'TWD': 'Taiwan Dollar',
  'MOP': 'Macanese Pataca',
  'BND': 'Brunei Dollar',
  'KHR': 'Cambodian Riel',
  'LAK': 'Lao Kip',
  'MMK': 'Myanmar Kyat',
  'MNT': 'Mongolian Tugrik',
  'KZT': 'Kazakhstani Tenge',
  'UZS': 'Uzbekistani Som',
  'GEL': 'Georgian Lari',
  'AMD': 'Armenian Dram',
  'AZN': 'Azerbaijani Manat',
  'JOD': 'Jordanian Dinar',
  'LBP': 'Lebanese Pound',
  'IQD': 'Iraqi Dinar',
  'IRR': 'Iranian Rial',
  'AFN': 'Afghan Afghani',
  'ETB': 'Ethiopian Birr',
  'TZS': 'Tanzanian Shilling',
  'UGX': 'Ugandan Shilling',
  'RWF': 'Rwandan Franc',
  'ZMW': 'Zambian Kwacha',
  'MZN': 'Mozambican Metical',
  'XOF': 'West African CFA Franc',
  'XAF': 'Central African CFA Franc',
  'MAD': 'Moroccan Dirham',
  'DZD': 'Algerian Dinar',
  'TND': 'Tunisian Dinar',
  'LYD': 'Libyan Dinar',
  'SDG': 'Sudanese Pound',
  'MUR': 'Mauritian Rupee',
  'BWP': 'Botswana Pula',
  'NAD': 'Namibian Dollar',
  'MWK': 'Malawian Kwacha',
  'XCD': 'East Caribbean Dollar',
  'TTD': 'Trinidad Dollar',
  'BBD': 'Barbadian Dollar',
  'BSD': 'Bahamian Dollar',
  'BZD': 'Belize Dollar',
  'HTG': 'Haitian Gourde',
  'HNL': 'Honduran Lempira',
  'NIO': 'Nicaraguan Cordoba',
  'PAB': 'Panamanian Balboa',
  'SVC': 'Salvadoran Colon',
  'VES': 'Venezuelan Bolivar',
  'GYD': 'Guyanese Dollar',
  'SRD': 'Surinamese Dollar',
  'FJD': 'Fiji Dollar',
  'PGK': 'Papua New Guinea Kina',
  'WST': 'Samoan Tala',
  'TOP': 'Tongan Pa\'anga',
  'XPF': 'CFP Franc',
  'ALL': 'Albanian Lek',
  'MKD': 'Macedonian Denar',
  'RSD': 'Serbian Dinar',
  'BAM': 'Bosnia-Herzegovina Mark',
  'MDL': 'Moldovan Leu',
  'BYN': 'Belarusian Ruble',
  'YER': 'Yemeni Rial',
  'SYP': 'Syrian Pound',
};

/// Renders minor units as a plain decimal for a text field the user edits
/// ("42.50"), with no currency symbol and no sign.
///
/// String manipulation, not division: going through a double reintroduces
/// exactly the rounding error the int64 representation exists to prevent.
String formatAmountForEditing(int cents) {
  final digits = cents.abs().toString().padLeft(3, '0');
  final whole = digits.substring(0, digits.length - 2);
  final fraction = digits.substring(digits.length - 2);
  return '${cents < 0 ? '-' : ''}$whole.$fraction';
}
