package pricing

import (
	"testing"

	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/vultr"
)

// TestChargeOneHourMinimum asserts Vultr's 1-hour minimum: even a request
// for a fraction of an hour bills a full hour.
func TestChargeOneHourMinimum(t *testing.T) {
	p := vultr.Plan{InvoiceType: "hourly"}
	r := Rate{HourlyMicros: 100_000} // $0.10/hr
	got, capped := Charge(p, r, 0.25)
	if got != 100_000 {
		t.Errorf("Charge(0.25h) = %d micros, want 100000 (one full hour)", got)
	}
	if capped {
		t.Error("an hourly plan should never report capped = true")
	}
}

// TestChargeMonthlyBelowCap: vc2-6c-16gb at 720h (30d) is $79.20, strictly
// below its $80/month cap -- so the cap must NOT bind, and the result must
// equal the plain hourly*hours figure exactly.
func TestChargeMonthlyBelowCap(t *testing.T) {
	p := vultr.Plan{InvoiceType: "monthly"}
	r := Rate{HourlyMicros: 110_000, MonthlyMicros: 80_000_000} // vc2-6c-16gb: $0.11/hr, $80/mo cap
	got, capped := Charge(p, r, 720)
	want := Micros(79_200_000) // $79.20
	if got != want {
		t.Errorf("Charge(720h) = %d, want %d ($79.20)", got, want)
	}
	if capped {
		t.Error("capped = true, want false: $79.20 is below the $80 cap, so the cap never binds")
	}
}

// TestChargeMonthlyAboveCap: a monthly-invoiced plan whose raw hourly*hours
// figure exceeds its monthly cap must be billed at the cap, with capped =
// true. Modeled on the LB rate (0.015/hr, $10 cap): 720h raw is $10.80,
// above the cap.
func TestChargeMonthlyAboveCap(t *testing.T) {
	p := vultr.Plan{InvoiceType: "monthly"}
	r := Rate{HourlyMicros: 15_000, MonthlyMicros: 10_000_000} // $0.015/hr, $10/mo cap
	got, capped := Charge(p, r, 720)
	want := Micros(10_000_000) // $10.00, the cap
	if got != want {
		t.Errorf("Charge(720h) = %d, want %d ($10.00, the cap)", got, want)
	}
	if !capped {
		t.Error("capped = false, want true: raw ($10.80) exceeds the $10 cap")
	}
}

// TestChargeHourlyNeverCapped is the case the plan calls out by name:
// vx1-g-4c-16g-240s is invoice_type "hourly" despite looking like an
// ordinary capped cloud plan, and looks up to $111.69 in its own
// monthly_cost field -- which Charge must never substitute in. 720 * 0.153 =
// $110.16, not $111.69.
func TestChargeHourlyNeverCapped(t *testing.T) {
	p := vultr.Plan{InvoiceType: "hourly"}
	r := Rate{HourlyMicros: 153_000, MonthlyMicros: 111_690_000} // vx1-g-4c-16g-240s
	got, capped := Charge(p, r, 720)
	want := Micros(110_160_000) // $110.16 = 720 * 0.153
	if got != want {
		t.Errorf("Charge(720h) = %d ($%.2f), want %d ($110.16)", got, got.Dollars(), want)
	}
	if capped {
		t.Error("capped = true, want false: invoice_type \"hourly\" is never capped, regardless of monthly_cost")
	}
	forbidden := Micros(111_690_000)
	if got == forbidden {
		t.Error("Charge returned the plan's monthly_cost verbatim -- hourly_cost must never be replaced by monthly_cost")
	}
}

// TestChargeMonthlyMultipleMonths exercises the months/remainder split for a
// duration spanning more than one 730-hour month.
func TestChargeMonthlyMultipleMonths(t *testing.T) {
	p := vultr.Plan{InvoiceType: "monthly"}
	r := Rate{HourlyMicros: 110_000, MonthlyMicros: 80_000_000}
	hours := 730.0*2 + 100 // two full months plus a 100h remainder
	got, _ := Charge(p, r, hours)
	remCost := Micros(11_000_000) // round(110000 * 100)
	want := 2*r.MonthlyMicros + min(remCost, r.MonthlyMicros)
	if got != want {
		t.Errorf("Charge(%vh) = %d, want %d", hours, got, want)
	}
}

// TestProrateSnapshotFooterFigure: the footer's "$X/month" figure, computed
// over exactly HoursPerMonth hours, must be a clean $0.05 * GB with no
// rounding artifact, since GB and 730 both divide out evenly here.
func TestProrateSnapshotFooterFigure(t *testing.T) {
	got := ProrateSnapshot(8, HoursPerMonth)
	want := Micros(400_000) // $0.05 * 8 GB = $0.40
	if got != want {
		t.Errorf("ProrateSnapshot(8, 730) = %d, want %d ($0.40)", got, want)
	}
}
