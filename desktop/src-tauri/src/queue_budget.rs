//! Shared request deadline port; no dependency on a particular job kind.
/// Supervisor capability: each RPC fits the remaining operation/cancel budget.
/// Shutdown must stop/reap the owner before receipt fallback or reconnection.
pub trait RequestBudget {
    fn deadline(&self) -> std::time::Instant;
}
pub struct FixedDeadline(pub std::time::Instant);
impl RequestBudget for FixedDeadline {
    fn deadline(&self) -> std::time::Instant {
        self.0
    }
}
