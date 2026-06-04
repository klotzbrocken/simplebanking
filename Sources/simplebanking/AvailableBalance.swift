import Foundation

/// Computes the "available" balance — the booked balance reduced by money that is
/// already on its way out (pending debits) but not yet booked.
///
/// Answers the user question "how much can I still spend?" and protects against an
/// unintended Dispo jump (overdraft) or a declined card at the till.
///
/// Pending **credits** are deliberately *not* counted: like the bank's own logic, an
/// incoming-but-not-yet-booked amount is not guaranteed and must not inflate the figure.
/// This is stricter than YAXI's `expected` field (which nets debits *and* credits) — so we
/// compute it ourselves from booked + pending debits rather than passing `expected` through.
///
/// `adjustedBooked` is expected to already be Dispo-adjusted (i.e. the output of
/// `BalanceAdjustment.computeAdjustedBalance`) so the available figure stays consistent with
/// the main displayed balance.
enum AvailableBalance {

    /// `adjustedBooked` + Σ(pending debits). Pending debits are negative, so the result is
    /// ≤ `adjustedBooked`. Returns `adjustedBooked` unchanged when there are no pending debits.
    static func compute(
        adjustedBooked: Double,
        pendingTx: [TransactionsResponse.Transaction]
    ) -> Double {
        adjustedBooked + pendingDebitSum(pendingTx)
    }

    /// Σ of all pending debit amounts (negative). `0` when there are none — callers use this to
    /// decide whether to show the "Verfügbar" sub-line at all (only when the delta ≠ 0).
    static func pendingDebitSum(_ pendingTx: [TransactionsResponse.Transaction]) -> Double {
        pendingTx
            .filter { $0.status == "pending" && $0.parsedAmount < 0 }
            .reduce(0.0) { $0 + $1.parsedAmount }
    }
}
