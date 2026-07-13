/// Public API for splitcore_sdk. Nothing under lib/src is exported except
/// through this file.
library;

export 'src/calc_api.dart' show SplitcoreCalc;
export 'src/ffi/native_calc.dart' show SplitcoreException;
export 'src/models.dart'
    show
        Balance,
        EqualSplitEntry,
        ExactSplitEntry,
        ExpenseInput,
        PercentSplitEntry,
        SettlementInput,
        ShareSplitEntry,
        Split,
        SplitRequestEntry,
        SplitSpec,
        Transfer;
