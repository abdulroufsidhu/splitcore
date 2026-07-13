// Dart mirrors of the JSON shapes accepted/returned by splitcore/ffi/handler.
// Field names on the wire (json:"..." tags in handler.go) are the source of
// truth; keep these in lockstep with that file.

/// A single split-request entry. Which fields are populated depends on
/// [SplitSpec.type] — the handler switches on that to decide what it reads.
sealed class SplitRequestEntry {
  const SplitRequestEntry();

  Map<String, dynamic> toJson();
}

class EqualSplitEntry extends SplitRequestEntry {
  const EqualSplitEntry({required this.memberId});

  final String memberId;

  @override
  Map<String, dynamic> toJson() => {'member_id': memberId};
}

class ExactSplitEntry extends SplitRequestEntry {
  const ExactSplitEntry({required this.memberId, required this.amountCents});

  final String memberId;
  final int amountCents;

  @override
  Map<String, dynamic> toJson() => {'member_id': memberId, 'amount_cents': amountCents};
}

class PercentSplitEntry extends SplitRequestEntry {
  const PercentSplitEntry({required this.memberId, required this.basisPoints});

  final String memberId;
  final int basisPoints;

  @override
  Map<String, dynamic> toJson() => {'member_id': memberId, 'basis_points': basisPoints};
}

class ShareSplitEntry extends SplitRequestEntry {
  const ShareSplitEntry({required this.memberId, required this.shares});

  final String memberId;
  final int shares;

  @override
  Map<String, dynamic> toJson() => {'member_id': memberId, 'shares': shares};
}

/// Request body for SplitcoreComputeSplits: {type, total_cents, entries[]}.
class SplitSpec {
  const SplitSpec._(this.type, this.totalCents, this.entries);

  factory SplitSpec.equal({required int totalCents, required List<String> memberIds}) =>
      SplitSpec._(
        'equal',
        totalCents,
        [for (final id in memberIds) EqualSplitEntry(memberId: id)],
      );

  factory SplitSpec.exact({required int totalCents, required List<ExactSplitEntry> entries}) =>
      SplitSpec._('exact', totalCents, entries);

  factory SplitSpec.percent({
    required int totalCents,
    required List<PercentSplitEntry> entries,
  }) =>
      SplitSpec._('percent', totalCents, entries);

  factory SplitSpec.shares({required int totalCents, required List<ShareSplitEntry> entries}) =>
      SplitSpec._('shares', totalCents, entries);

  final String type;
  final int totalCents;
  final List<SplitRequestEntry> entries;

  Map<String, dynamic> toJson() => {
        'type': type,
        'total_cents': totalCents,
        'entries': [for (final e in entries) e.toJson()],
      };
}

/// A resolved split-line, returned by ComputeSplits and consumed by
/// ComputeBalances ({splits: [...]}).
class Split {
  const Split({required this.memberId, required this.amountCents});

  factory Split.fromJson(Map<String, dynamic> json) =>
      Split(memberId: json['member_id'] as String, amountCents: json['amount_cents'] as int);

  final String memberId;
  final int amountCents;

  Map<String, dynamic> toJson() => {'member_id': memberId, 'amount_cents': amountCents};

  @override
  bool operator ==(Object other) =>
      other is Split && other.memberId == memberId && other.amountCents == amountCents;

  @override
  int get hashCode => Object.hash(memberId, amountCents);

  @override
  String toString() => 'Split(memberId: $memberId, amountCents: $amountCents)';
}

/// A member's net position (+ = owed money, − = owes), matching
/// balance.Balance / settle.Balance's {member_id, net_cents}.
class Balance {
  const Balance({required this.memberId, required this.netCents});

  factory Balance.fromJson(Map<String, dynamic> json) =>
      Balance(memberId: json['member_id'] as String, netCents: json['net_cents'] as int);

  final String memberId;
  final int netCents;

  Map<String, dynamic> toJson() => {'member_id': memberId, 'net_cents': netCents};

  @override
  bool operator ==(Object other) =>
      other is Balance && other.memberId == memberId && other.netCents == netCents;

  @override
  int get hashCode => Object.hash(memberId, netCents);

  @override
  String toString() => 'Balance(memberId: $memberId, netCents: $netCents)';
}

/// A suggested settlement transfer from SimplifyDebts.
class Transfer {
  const Transfer({required this.fromMemberId, required this.toMemberId, required this.amountCents});

  factory Transfer.fromJson(Map<String, dynamic> json) => Transfer(
        fromMemberId: json['from_member_id'] as String,
        toMemberId: json['to_member_id'] as String,
        amountCents: json['amount_cents'] as int,
      );

  final String fromMemberId;
  final String toMemberId;
  final int amountCents;

  Map<String, dynamic> toJson() =>
      {'from_member_id': fromMemberId, 'to_member_id': toMemberId, 'amount_cents': amountCents};

  @override
  bool operator ==(Object other) =>
      other is Transfer &&
      other.fromMemberId == fromMemberId &&
      other.toMemberId == toMemberId &&
      other.amountCents == amountCents;

  @override
  int get hashCode => Object.hash(fromMemberId, toMemberId, amountCents);

  @override
  String toString() =>
      'Transfer(fromMemberId: $fromMemberId, toMemberId: $toMemberId, amountCents: $amountCents)';
}

/// One expense, as fed into ComputeBalances's {expenses: [...]}.
class ExpenseInput {
  const ExpenseInput({required this.payerId, required this.amountCents, required this.splits});

  final String payerId;
  final int amountCents;
  final List<Split> splits;

  Map<String, dynamic> toJson() => {
        'payer_id': payerId,
        'amount_cents': amountCents,
        'splits': [for (final s in splits) s.toJson()],
      };
}

/// One settlement, as fed into ComputeBalances's {settlements: [...]}.
class SettlementInput {
  const SettlementInput({
    required this.fromMemberId,
    required this.toMemberId,
    required this.amountCents,
  });

  final String fromMemberId;
  final String toMemberId;
  final int amountCents;

  Map<String, dynamic> toJson() =>
      {'from_member_id': fromMemberId, 'to_member_id': toMemberId, 'amount_cents': amountCents};
}
