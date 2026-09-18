package pricing

import (
	"fmt"
	"math"
	"strings"

	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/vultr"
)

// Rate is the hourly/monthly figures Charge bills against: either a catalog
// plan's own rate (region-adjusted via vultr.Plan.RateFor), or one of the
// hardcoded LB/NAT constants in rates.go paired with their cap.
// MonthlyMicros of 0 means "no cap" -- see Charge.
type Rate struct {
	HourlyMicros  Micros
	MonthlyMicros Micros
}

// Charge returns the cost of `hours` on plan p at rate r, and whether the cap
// bound. This is the plan's own math, unchanged: invoice_type is the cap
// discriminator (not a literal 672/730-hour cutoff and not the plan-ID
// prefix -- vx1-g-4c-16g-240s is invoice_type "hourly" despite looking like
// an ordinary cloud plan), capping is on DOLLARS via MonthlyMicros, and a
// partial final month is itself capped at the same monthly rate.
func Charge(p vultr.Plan, r Rate, hours float64) (Micros, bool) {
	h := math.Max(1, hours) // Vultr's 1-hour minimum
	raw := Micros(math.Round(float64(r.HourlyMicros) * h))
	if p.InvoiceType != "monthly" || r.MonthlyMicros == 0 {
		return raw, false // vcg / vdm / vx1 / hourly metal
	}
	months := math.Floor(h / HoursPerMonth)
	rem := h - months*HoursPerMonth
	total := Micros(months)*r.MonthlyMicros +
		min(Micros(math.Round(float64(r.HourlyMicros)*rem)), r.MonthlyMicros)
	return total, total < raw
}

// ProrateSnapshot returns the cost of storing sizeGB of snapshot for `hours`,
// at SnapshotMicrosPerGBMonth spread evenly across a HoursPerMonth month.
// Deliberately NOT run through Charge: Vultr snapshot storage has no
// invoice_type and no monthly cap to discriminate on, just a flat per-GB
// monthly rate.
func ProrateSnapshot(sizeGB float64, hours float64) Micros {
	h := math.Max(1, hours)
	perGBPerHour := float64(SnapshotMicrosPerGBMonth) / HoursPerMonth
	return Micros(math.Round(perGBPerHour * sizeGB * h))
}

// LineItem is one priced Resource: its resolved rate (per unit -- Qty is
// applied only to the Costs map, never to HourlyMicros/MonthlyMicros, so the
// rendered $/hr column always reads as a per-instance figure) and its cost
// across every requested Duration.
type LineItem struct {
	Resource    Resource
	PlanFound   bool
	InvoiceType string
	// HourlyMicros/MonthlyMicros are PER UNIT, region-adjusted if Regional.
	HourlyMicros  Micros
	MonthlyMicros Micros
	Regional      bool

	Costs  map[string]Micros // keyed by Duration.Label, already Qty-multiplied
	Capped map[string]bool   // keyed by Duration.Label

	Warnings []string
}

// PriceResult is the full priced report.
type PriceResult struct {
	Region string
	Items  []LineItem
	Totals map[string]Micros // keyed by Duration.Label

	// RecurringAfterDestroy is the snapshot's ongoing monthly storage cost --
	// the only thing `terraform destroy` does not remove. See resource.go's
	// SurvivesDestroy field.
	RecurringAfterDestroy Micros

	// Incomplete is true once --allow-unknown-plans downgraded at least one
	// unknown-plan-at-qty>=1 condition from fatal to a warning; the total is
	// then a floor, not a real total, and callers should say so.
	Incomplete bool

	// Warnings are catalog- or region-level messages not tied to one line
	// item (currently unused directly, kept for callers that want a flat
	// list; per-item warnings live on LineItem.Warnings).
	Warnings []string
}

// AllWarnings flattens every per-item warning plus the result-level ones, in
// resource order, for renderers that want one flat list (e.g. --json's
// top-level "warnings" array).
func (r PriceResult) AllWarnings() []string {
	out := append([]string(nil), r.Warnings...)
	for _, item := range r.Items {
		out = append(out, item.Warnings...)
	}
	return out
}

// Price resolves every Resource against catalog and bills it across
// durations. It returns a non-nil error only for the one truly fatal
// pricing condition in the plan's error-handling table: a referenced plan ID
// that does not exist in the catalog at Qty >= 1, and allowUnknownPlans is
// false. Every other condition in that table (Qty 0, region not in the
// plan's locations, etc.) becomes a warning on the affected LineItem instead.
func Price(resources []Resource, catalog vultr.Catalog, region string, durations []Duration, allowUnknownPlans bool) (PriceResult, error) {
	result := PriceResult{Region: region, Totals: make(map[string]Micros, len(durations))}
	for _, d := range durations {
		result.Totals[d.Label] = 0
	}

	var fatal []string

	for _, res := range resources {
		item := LineItem{Resource: res, Costs: map[string]Micros{}, Capped: map[string]bool{}}

		switch res.Kind {
		case KindFree:
			for _, d := range durations {
				item.Costs[d.Label] = 0
			}

		case KindStorage:
			for _, d := range durations {
				item.Costs[d.Label] = ProrateSnapshot(res.SizeGB, d.Hours) * Micros(res.Qty)
			}
			if res.SurvivesDestroy {
				result.RecurringAfterDestroy += ProrateSnapshot(res.SizeGB, HoursPerMonth) * Micros(res.Qty)
			}

		case KindFixedRate:
			// Modeled as a synthetic "monthly" (capped) plan: LB/NAT bill
			// hourly with a hard monthly ceiling, which is exactly what
			// Charge already implements for a real invoice_type=="monthly"
			// plan -- see rates.go for the cited $/hr and cap figures.
			fixedPlan := vultr.Plan{ID: "-- fixed --", InvoiceType: "monthly"}
			item.InvoiceType = fixedPlan.InvoiceType
			item.HourlyMicros = res.FixedRate.HourlyMicros
			item.MonthlyMicros = res.FixedRate.MonthlyMicros
			for _, d := range durations {
				c, capped := Charge(fixedPlan, res.FixedRate, d.Hours)
				item.Costs[d.Label] = c * Micros(res.Qty)
				item.Capped[d.Label] = capped
			}

		case KindPlan:
			p, found := catalog.Lookup(res.PlanID)
			item.PlanFound = found

			if !found {
				if res.Qty >= 1 {
					if allowUnknownPlans {
						item.Warnings = append(item.Warnings, fmt.Sprintf("plan %q not found in catalog; priced as $0 because --allow-unknown-plans was set", res.PlanID))
						result.Incomplete = true
					} else {
						fatal = append(fatal, fmt.Sprintf("%s: plan %q not found in catalog", res.Label, res.PlanID))
					}
				} else {
					item.Warnings = append(item.Warnings, fmt.Sprintf("plan %q not found in catalog (qty 0, so this is informational only)", res.PlanID))
				}
				for _, d := range durations {
					item.Costs[d.Label] = 0
				}
				result.Items = append(result.Items, item)
				continue
			}

			if !p.HasLocation(region) {
				item.Warnings = append(item.Warnings, fmt.Sprintf("plan %q does not list region %q among its locations; pricing it anyway (the unauthenticated /v2/plans endpoint under-reports availability -- see README)", res.PlanID, region))
			}

			hourly, monthly, regional := p.RateFor(region)
			item.HourlyMicros = Micros(hourly)
			item.MonthlyMicros = Micros(monthly)
			item.InvoiceType = p.InvoiceType
			item.Regional = regional

			regionalPlan := p
			regionalPlan.HourlyMicros = hourly
			regionalPlan.MonthlyMicros = monthly
			rate := Rate{HourlyMicros: Micros(hourly), MonthlyMicros: Micros(monthly)}

			for _, d := range durations {
				c, capped := Charge(regionalPlan, rate, d.Hours)
				item.Costs[d.Label] = c * Micros(res.Qty)
				item.Capped[d.Label] = capped
			}
		}

		for _, d := range durations {
			result.Totals[d.Label] += item.Costs[d.Label]
		}
		result.Items = append(result.Items, item)
	}

	if len(fatal) > 0 {
		return result, fmt.Errorf("plan(s) not found in catalog, refusing to price them as $0 (pass --allow-unknown-plans to override):\n  %s", strings.Join(fatal, "\n  "))
	}
	return result, nil
}
