// Exports a group's whole ledger as CSV. The destination is a
// spreadsheet — the point of the feature is "let me check these numbers
// myself" — so the shape is one row per money movement, not a nested
// document.
import 'expenses_api.dart';
import 'groups_api.dart';
import 'settlements_api.dart';

class ExportApi {
  ExportApi(this._groups, this._expenses, this._settlements);

  final GroupsApi _groups;
  final ExpensesApi _expenses;
  final SettlementsApi _settlements;

  /// The group's expenses (one row per member's share) and settlements
  /// (one row each), oldest first.
  Future<String> groupToCsv(String groupId) async {
    final group = await _groups.getGroup(groupId);
    final members = await _groups.listMembers(groupId);
    final nameFor = {for (final m in members) m.id: m.name.isEmpty ? m.userId : m.name};

    String who(String memberId) => nameFor[memberId] ?? memberId;

    final rows = <_Row>[];

    for (final expense in await _expenses.listAllExpenses(groupId)) {
      for (final entry in await _expenses.listSplitEntries(expense.id)) {
        rows.add(
          _Row(
            date: expense.date,
            type: 'expense',
            description: expense.description,
            payer: who(expense.payerMemberId),
            member: who(entry.memberId),
            amountCents: entry.amountCents,
          ),
        );
      }
    }

    for (final s in await _settlements.listAllSettlements(groupId)) {
      rows.add(
        _Row(
          date: s.date,
          type: 'settlement',
          description: s.note,
          payer: who(s.fromMemberId),
          member: who(s.toMemberId),
          amountCents: s.amountCents,
        ),
      );
    }

    rows.sort((a, b) => a.date.compareTo(b.date));

    final buffer = StringBuffer('date,type,description,payer,member,amount,currency\n');
    for (final row in rows) {
      buffer.writeln(
        [
          row.date.toIso8601String().substring(0, 10),
          row.type,
          row.description,
          row.payer,
          row.member,
          formatMinorUnits(row.amountCents),
          group.currency,
        ].map(_csvField).join(','),
      );
    }
    return buffer.toString();
  }
}

/// Renders integer minor units as a decimal string by string manipulation
/// only — going through a double would reintroduce exactly the rounding
/// error the int64 representation exists to prevent.
String formatMinorUnits(int cents) {
  final negative = cents < 0;
  final digits = cents.abs().toString().padLeft(3, '0');
  final whole = digits.substring(0, digits.length - 2);
  final fraction = digits.substring(digits.length - 2);
  return '${negative ? '-' : ''}$whole.$fraction';
}

/// RFC 4180: quote a field containing a comma, quote, or newline, and
/// double any quote inside it. Without this, one expense described as
/// "Dinner, drinks" shifts every later column by one.
String _csvField(String value) {
  if (!value.contains(RegExp(r'[",\n\r]'))) return value;
  return '"${value.replaceAll('"', '""')}"';
}

class _Row {
  _Row({
    required this.date,
    required this.type,
    required this.description,
    required this.payer,
    required this.member,
    required this.amountCents,
  });

  final DateTime date;
  final String type;
  final String description;
  final String payer;
  final String member;
  final int amountCents;
}
