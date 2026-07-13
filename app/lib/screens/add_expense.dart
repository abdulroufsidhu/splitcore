// 1c — Add expense: amount, paid-by, split type (Equal/Exact/%/Shares) with
// a live per-member preview via previewSplit, and receipt attach.
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Split;
import 'package:image_picker/image_picker.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../display_name.dart';
import '../money.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/money_text.dart';

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
  late String _payerMemberId = widget.members.firstWhere((m) => m.userId == widget.me.id).id;
  List<Split> _preview = [];
  Uint8List? _receiptBytes;
  bool _saving = false;
  String? _error;

  int get _totalCents => ((double.tryParse(_amountController.text) ?? 0) * 100).round();

  SplitSpec _buildSpec() {
    final memberIds = widget.members.map((m) => m.id).toList();
    switch (_splitType) {
      case _SplitType.equal:
        return SplitSpec.equal(totalCents: _totalCents, memberIds: memberIds);
      case _SplitType.exact:
      case _SplitType.percent:
      case _SplitType.shares:
        // v1: exact/%/shares default to an equal split of the same members
        // until per-member entry fields are built — the tab switches, the
        // math underneath is equal for now.
        return SplitSpec.equal(totalCents: _totalCents, memberIds: memberIds);
    }
  }

  Future<void> _updatePreview() async {
    if (_totalCents <= 0) {
      setState(() => _preview = []);
      return;
    }
    final splits = await widget.sdk.previewSplit(_buildSpec());
    if (mounted) setState(() => _preview = splits);
  }

  Future<void> _pickReceipt() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.camera);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() => _receiptBytes = bytes);
  }

  Future<void> _save() async {
    if (_totalCents <= 0 || _descriptionController.text.trim().isEmpty) {
      setState(() => _error = 'Enter an amount and description.');
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
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: SliceColors.muted)),
        ),
        title: const Text('New expense'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text('Save', style: TextStyle(color: _saving ? SliceColors.muted : SliceColors.positive, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: SingleChildScrollView(
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
                      Text(currencySymbol(widget.group.currency), style: moneyStyle(size: 34, color: SliceColors.muted)),
                      IntrinsicWidth(
                        child: TextField(
                          controller: _amountController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: moneyStyle(size: 40),
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(border: InputBorder.none, hintText: '0.00'),
                          onChanged: (_) => _updatePreview(),
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    controller: _descriptionController,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(border: UnderlineInputBorder(), hintText: 'Description'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text('PAID BY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: SliceColors.muted)),
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
            const Text('SPLIT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: SliceColors.muted)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(color: SliceColors.chip, borderRadius: BorderRadius.circular(10)),
              child: Row(
                children: [
                  for (final type in _SplitType.values)
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() => _splitType = type);
                          _updatePreview();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: _splitType == type ? SliceColors.card : null,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            _label(type),
                            style: TextStyle(
                              fontWeight: _splitType == type ? FontWeight.w700 : FontWeight.w600,
                              fontSize: 13,
                              color: _splitType == type ? SliceColors.ink : SliceColors.muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (_preview.isNotEmpty)
              Container(
                decoration: BoxDecoration(
                  color: SliceColors.card,
                  border: Border.all(color: SliceColors.border),
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
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: SliceColors.ink),
                              ),
                            ),
                            MoneyText(split.amountCents, widget.group.currency, signed: false, size: 14, weight: FontWeight.w500),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 18),
            const Text('RECEIPT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: SliceColors.muted)),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _pickReceipt,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  border: Border.all(color: SliceColors.border, style: BorderStyle.solid),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.camera_alt_outlined, size: 18, color: SliceColors.ink),
                    const SizedBox(width: 8),
                    Text(
                      _receiptBytes == null ? 'Attach receipt' : 'Receipt attached · retake',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, color: SliceColors.ink),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: SliceColors.negative)),
            ],
            const SizedBox(height: 40),
          ],
        ),
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
