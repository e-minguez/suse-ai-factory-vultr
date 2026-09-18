package pricing

// Hardcoded because no rate card for these three items exists anywhere in
// Vultr's API -- they're billed on the account invoice, not quoted by
// GET /v2/plans. Each is cited at the constant that carries it.

const (
	// LBHourlyMicros / LBMonthlyCapMicros: Vultr Load Balancers bill $0.015
	// per node per hour, capped at $10/node/month.
	// Source: https://www.vultr.com/pricing/ ("Load Balancers") and
	// https://docs.vultr.com/vultr-load-balancers-overview ("Pricing").
	// 0.015 * 672 = 10.08, so the $10 monthly figure and 672 hours are each
	// other's rounding, not two independently-published numbers -- and it is
	// exactly why capping must be done on dollars (MonthlyMicros) rather than
	// on a literal 672-hour cutoff (see Charge in price.go).
	LBHourlyMicros     Micros = 15_000
	LBMonthlyCapMicros Micros = 10_000_000

	// NATHourlyMicros / NATMonthlyCapMicros: Vultr NAT Gateways bill $0.03
	// per hour, capped at $20/month.
	// Source: https://www.vultr.com/pricing/#nat-gateways.
	// 0.03 * 672 = 20.16, same relationship as the LB figures above.
	NATHourlyMicros     Micros = 30_000
	NATMonthlyCapMicros Micros = 20_000_000

	// SnapshotMicrosPerGBMonth: Vultr Snapshots bill $0.05/GB/month of stored
	// snapshot size, with no hourly rate and no cap -- see ProrateSnapshot.
	// Source: https://docs.vultr.com/vultr-snapshots-overview ("Billing").
	SnapshotMicrosPerGBMonth Micros = 50_000
)

// HoursPerMonth is the 672-vs-730 split's uncapped side: the length of the
// month pricing.ProrateSnapshot spreads storage cost across, and the same
// figure Charge below uses for its own monthly/partial-month split. Kept as
// a named constant here (rather than only the literal inside Charge) because
// ProrateSnapshot needs it too and the two must agree.
const HoursPerMonth = 730.0
