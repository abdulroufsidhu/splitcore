// Searchable ISO-currency sheet, shared by new_group and add-person (home).
import 'package:flutter/material.dart';

import '../money.dart';
import '../theme.dart';

/// Opens a bottom sheet to search & pick an ISO currency code. Returns null
/// if dismissed without a selection.
Future<String?> pickCurrency(BuildContext context, String current) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _CurrencyPickerSheet(current: current),
  );
}

class _CurrencyPickerSheet extends StatefulWidget {
  const _CurrencyPickerSheet({required this.current});

  final String current;

  @override
  State<_CurrencyPickerSheet> createState() => _CurrencyPickerSheetState();
}

class _CurrencyPickerSheetState extends State<_CurrencyPickerSheet> {
  final _query = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    final q = _query.text.trim().toLowerCase();
    final matches = isoCurrencies.entries
        .where((e) => q.isEmpty || e.key.toLowerCase().contains(q) || e.value.toLowerCase().contains(q))
        .toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _query,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Search currency', prefixIcon: Icon(Icons.search)),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: matches.length,
                itemBuilder: (context, i) {
                  final entry = matches[i];
                  return ListTile(
                    leading: Text(currencySymbol(entry.key), style: moneyStyle(size: 18, color: slice.ink)),
                    title: Text(entry.key, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(entry.value),
                    trailing: entry.key == widget.current ? Icon(Icons.check, color: slice.ink) : null,
                    onTap: () => Navigator.of(context).pop(entry.key),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
