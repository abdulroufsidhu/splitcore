// 1c — Add expense: amount, paid-by, split type (Equal/Exact/%/Shares) with
// a live per-member preview via previewSplit, and receipt attach.
//
// Exact/%/Shares each keep their own controller map (different units: cents,
// basis points, integer shares) seeded with sensible equal-ish defaults the
// first time a tab is opened, so switching tabs doesn't lose typed values.
// The SDK/native side already fully implements exact/percent/shares splits
// (SplitSpec.exact/.percent/.shares) — this file only had to stop hardcoding
// SplitSpec.equal for every tab.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Split;
import 'package:image_picker/image_picker.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../display_name.dart';
import '../money.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/money_text.dart';
import '../widgets/page_body.dart';

enum _SplitType { equal, exact, percent, shares }

class AddExpenseScreen extends StatefulWidget {
  const AddExpenseScreen({
    super.key,
    required this.sdk,
    required this.group,
    required this.members,
    required this.me,
  });

  final SplitcoreSdk sdk;
  final Group group;
  final List<GroupMember> members;
  final AppUser me;

  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  _SplitType _splitType = _SplitType.equal;
  late String _payerMemberId =
      memberFor(widget.members, widget.me.id)?.id ??
      (widget.members.isNotEmpty ? widget.members.first.id : '');
  final Map<String, TextEditingController> _exactControllers = {};
  final Map<String, TextEditingController> _percentControllers = {};
  final Map<String, TextEditingController> _shareControllers = {};
  List<Split> _preview = [];
  Uint8List? _receiptBytes;
  bool _saving = false;
  String? _error;
  Timer? _previewDebounce;
  int _previewRequest = 0;

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _amountController.dispose();
    _descriptionController.dispose();
    for (final c in _exactControllers.values) {
      c.dispose();
    }
    for (final c in _percentControllers.values) {
      c.dispose();
    }
    for (final c in _shareControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  int get _totalCents => ((double.tryParse(_amountController.text) ?? 0) * 100).round();

  double _num(TextEditingController? c) => double.tryParse(c?.text ?? '') ?? 0;
  int _centsOf(TextEditingController? c) => (_num(c) * 100).round();
  int _basisPointsOf(TextEditingController? c) => (_num(c) * 100).round();
  int _sharesOf(TextEditingController? c) => int.tryParse(c?.text ?? '') ?? 0;

  /// Lazily fills the controller map for [type] with an equal-ish starting
  /// point the first time that tab is opened, so it isn't blank.
  void _seedSplitControllers(_SplitType type) {
    final ids = widget.members.map((m) => m.id).toList();
    if (ids.isEmpty) return;
    switch (type) {
      case _SplitType.equal:
        return;
      case _SplitType.exact:
        if (_exactControllers.isNotEmpty) return;
        final each = _totalCents / ids.length / 100;
        for (final id in ids) {
          _exactControllers[id] = TextEditingController(text: each.toStringAsFixed(2));
        }
        return;
      case _SplitType.percent:
        if (_percentControllers.isNotEmpty) return;
        final each = 100 / ids.length;
        for (final id in ids) {
          _percentControllers[id] = TextEditingController(text: each.toStringAsFixed(2));
        }
        return;
      case _SplitType.shares:
        if (_shareControllers.isNotEmpty) return;
        for (final id in ids) {
          _shareControllers[id] = TextEditingController(text: '1');
        }
        return;
    }
  }

  SplitSpec _buildSpec() {
    final memberIds = widget.members.map((m) => m.id).toList();
    switch (_splitType) {
      case _SplitType.equal:
        return SplitSpec.equal(totalCents: _totalCents, memberIds: memberIds);
      case _SplitType.exact:
        return SplitSpec.exact(
          totalCents: _totalCents,
          entries: [
            for (final id in memberIds)
              ExactSplitEntry(memberId: id, amountCents: _centsOf(_exactControllers[id])),
          ],
        );
      case _SplitType.percent:
        return SplitSpec.percent(
          totalCents: _totalCents,
          entries: [
            for (final id in memberIds)
              PercentSplitEntry(memberId: id, basisPoints: _basisPointsOf(_percentControllers[id])),
          ],
        );
      case _SplitType.shares:
        return SplitSpec.shares(
          totalCents: _totalCents,
          entries: [
            for (final id in memberIds)
              ShareSplitEntry(memberId: id, shares: _sharesOf(_shareControllers[id])),
          ],
        );
    }
  }

  /// Null when the current split type's inputs are consistent enough to
  /// preview/save; otherwise a user-facing message.
  String? _splitValidationError() {
    switch (_splitType) {
      case _SplitType.equal:
        return null;
      case _SplitType.exact:
        final sum = widget.members.fold<int>(0, (s, m) => s + _centsOf(_exactControllers[m.id]));
        if (sum != _totalCents) {
          return 'Exact amounts must add up to the total (currently ${formatMoney(sum, widget.group.currency)} of ${formatMoney(_totalCents, widget.group.currency)}).';
        }
        return null;
      case _SplitType.percent:
        final sum = widget.members.fold<int>(
          0,
          (s, m) => s + _basisPointsOf(_percentControllers[m.id]),
        );
        if (sum != 10000) {
          return 'Percentages must add up to 100% (currently ${(sum / 100).toStringAsFixed(2)}%).';
        }
        return null;
      case _SplitType.shares:
        final anyInvalid = widget.members.any((m) => _sharesOf(_shareControllers[m.id]) < 1);
        if (anyInvalid) return 'Each person needs at least 1 share.';
        return null;
    }
  }

  /// Debounced entry point for onChanged handlers — typing fires this on
  /// every keystroke, so wait for a pause before hitting the FFI/isolate
  /// preview call rather than firing one per character.
  void _schedulePreview() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 250), _updatePreview);
  }

  Future<void> _updatePreview() async {
    if (_totalCents <= 0 || _splitValidationError() != null) {
      setState(() => _preview = []);
      return;
    }
    // Requests can complete out of order (isolate hop); only the latest
    // request's result is allowed to land.
    final request = ++_previewRequest;
    final splits = await widget.sdk.previewSplit(_buildSpec());
    if (mounted && request == _previewRequest) setState(() => _preview = splits);
  }

  Future<void> _pickReceipt() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      final picked = await ImagePicker().pickImage(source: source);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      setState(() => _receiptBytes = bytes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Couldn't attach receipt: $e")));
    }
  }

  Future<void> _save() async {
    if (_totalCents <= 0 || _descriptionController.text.trim().isEmpty) {
      setState(() => _error = 'Enter an amount and description.');
      return;
    }
    final splitError = _splitValidationError();
    if (splitError != null) {
      setState(() => _error = splitError);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final expense = await widget.sdk.expenses.createExpense(
        groupId: widget.group.id,
        payerMemberId: _payerMemberId,
        description: _descriptionController.text.trim(),
        date: DateTime.now(),
        split: _buildSpec(),
      );
      if (_receiptBytes != null) {
        final entries = await widget.sdk.expenses.listSplitEntries(expense.id);
        if (entries.isNotEmpty) {
          await widget.sdk.expenses.attachReceipt(entries.first.id, _receiptBytes!);
        }
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    final splitError = _splitValidationError();
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 88,
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: slice.muted)),
        ),
        title: const Text('New expense'),
        actions: [
          TextButton(
            onPressed: (_saving || splitError != null) ? null : _save,
            child: Text(
              'Save',
              style: TextStyle(
                color: _saving ? slice.muted : slice.positive,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: PageBody(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            currencySymbol(widget.group.currency),
                            style: moneyStyle(size: 34, color: slice.muted),
                          ),
                          IntrinsicWidth(
                            child: TextField(
                              controller: _amountController,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              style: moneyStyle(size: 40, color: slice.ink),
                              textAlign: TextAlign.center,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                hintText: '0.00',
                              ),
                              onChanged: (_) => _schedulePreview(),
                            ),
                          ),
                        ],
                      ),
                      TextField(
                        controller: _descriptionController,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          border: UnderlineInputBorder(),
                          hintText: 'Description',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text('PAID BY', style: sectionLabelStyle(slice.muted)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in widget.members)
                      ChoiceChip(
                        label: Text(displayName(m, widget.me)),
                        selected: _payerMemberId == m.id,
                        onSelected: (_) => setState(() => _payerMemberId = m.id),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text('SPLIT', style: sectionLabelStyle(slice.muted)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: slice.chip,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      for (final type in _SplitType.values)
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _splitType = type;
                                _seedSplitControllers(type);
                              });
                              _updatePreview();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                color: _splitType == type ? slice.card : null,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                _label(type),
                                style: TextStyle(
                                  fontWeight: _splitType == type
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  fontSize: 13,
                                  color: _splitType == type ? slice.ink : slice.muted,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _splitType == _SplitType.equal ? _equalPreview(slice) : _editableSplitRows(slice),
                if (splitError != null) ...[
                  const SizedBox(height: 8),
                  Text(splitError, style: TextStyle(fontSize: 12, color: slice.negative)),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Text('RECEIPT', style: sectionLabelStyle(slice.muted)),
                    const SizedBox(width: 6),
                    Text('(optional)', style: TextStyle(fontSize: 11, color: slice.muted)),
                  ],
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: _pickReceipt,
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      border: Border.all(color: slice.border, style: BorderStyle.solid),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.camera_alt_outlined, size: 18, color: slice.ink),
                        const SizedBox(width: 8),
                        Text(
                          _receiptBytes == null ? 'Attach receipt' : 'Receipt attached · retake',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                            color: slice.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: slice.negative)),
                ],
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Read-only computed preview — used only for Equal, where there's
  /// nothing for the user to type.
  Widget _equalPreview(SliceTheme slice) {
    if (_preview.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: slice.card,
        border: Border.all(color: slice.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (final split in _preview)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                children: [
                  Avatar(_memberLabel(split.memberId), size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _memberDisplayName(split.memberId),
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: slice.ink),
                    ),
                  ),
                  MoneyText(
                    split.amountCents,
                    widget.group.currency,
                    signed: false,
                    size: 14,
                    weight: FontWeight.w500,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Editable per-member rows for Exact/%/Shares, with the FFI-computed
  /// resulting amount shown alongside once the inputs are valid.
  Widget _editableSplitRows(SliceTheme slice) {
    final controllers = switch (_splitType) {
      _SplitType.exact => _exactControllers,
      _SplitType.percent => _percentControllers,
      _SplitType.shares => _shareControllers,
      _SplitType.equal => const <String, TextEditingController>{},
    };
    final suffix = switch (_splitType) {
      _SplitType.percent => '%',
      _SplitType.shares => 'sh',
      _ => null,
    };
    return Container(
      decoration: BoxDecoration(
        color: slice.card,
        border: Border.all(color: slice.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (final m in widget.members)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Avatar(initialsFor(m, widget.me), size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      displayName(m, widget.me),
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: slice.ink),
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: controllers[m.id],
                      keyboardType: TextInputType.numberWithOptions(
                        decimal: _splitType != _SplitType.shares,
                      ),
                      textAlign: TextAlign.right,
                      style: moneyStyle(size: 14, weight: FontWeight.w500, color: slice.ink),
                      decoration: InputDecoration(
                        isDense: true,
                        suffixText: suffix,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => _schedulePreview(),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _label(_SplitType type) => switch (type) {
    _SplitType.equal => 'Equal',
    _SplitType.exact => 'Exact',
    _SplitType.percent => '%',
    _SplitType.shares => 'Shares',
  };

  String _memberDisplayName(String memberId) {
    final member = widget.members.where((m) => m.id == memberId);
    return member.isEmpty ? memberId : displayName(member.first, widget.me);
  }

  String _memberLabel(String memberId) {
    final member = widget.members.where((m) => m.id == memberId);
    return member.isEmpty ? '?' : initialsFor(member.first, widget.me);
  }
}
