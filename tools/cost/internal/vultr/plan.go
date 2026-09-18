// Package vultr fetches and decodes Vultr's public plan catalog
// (GET /v2/plans, GET /v2/plans-metal) and offers a small Catalog interface
// so pricing can be tested against a fake instead of the network.
package vultr

import (
	"encoding/json"
	"fmt"
	"math/big"
)

// Plan is one entry from GET /v2/plans or /v2/plans-metal, trimmed to what
// pricing needs. HourlyMicros/MonthlyMicros are hourly_cost/monthly_cost
// verbatim -- never one derived from the other. Measured across the live
// catalog, monthly_cost/hourly_cost ranges from 664 to 1363 depending on the
// plan (vc2-6c-16gb is 727.3, vbm-24c-384gb-amd5 is 1363), so treating either
// figure as authoritative for the other silently mis-prices a plan.
type Plan struct {
	ID          string `json:"id"`
	InvoiceType string `json:"invoice_type"` // "monthly" or "hourly" -- the cap discriminator; see pricing.Charge

	HourlyMicros  int64 `json:"hourly_micros"`  // dollars * 1_000_000, from hourly_cost
	MonthlyMicros int64 `json:"monthly_micros"` // dollars * 1_000_000, from monthly_cost

	Locations []string `json:"locations"`

	// LocationCost holds a per-region override of both Hourly/MonthlyMicros,
	// keyed by region ID (e.g. "sao"). Present on roughly a third of live
	// cloud plans as of 2026-09, absent (nil) on every bare metal plan --
	// the API's /v2/plans-metal responses carry no location_cost key at all.
	// See the README's Known limits.
	LocationCost map[string]LocationCost `json:"location_cost,omitempty"`
}

// LocationCost is one region's override of a Plan's hourly/monthly cost.
// Vultr's API documents this as a full replacement of both figures, not a
// delta on top of the base rate.
type LocationCost struct {
	HourlyMicros  int64 `json:"hourly_micros"`
	MonthlyMicros int64 `json:"monthly_micros"`
}

// RateFor returns the plan's hourly/monthly cost, replaced by region's
// LocationCost override when one exists.
func (p Plan) RateFor(region string) (hourlyMicros, monthlyMicros int64, regional bool) {
	if lc, ok := p.LocationCost[region]; ok {
		return lc.HourlyMicros, lc.MonthlyMicros, true
	}
	return p.HourlyMicros, p.MonthlyMicros, false
}

// HasLocation reports whether region appears in the plan's own Locations
// list. A false here is deliberately NOT treated as unpriceable by this
// tool: variables.tf:319 records that this same unauthenticated endpoint's
// locations field under-reports real availability, and availability.tf's
// authenticated check -- not this one -- is this repo's authority on stock.
// Callers should warn and price anyway.
func (p Plan) HasLocation(region string) bool {
	for _, l := range p.Locations {
		if l == region {
			return true
		}
	}
	return false
}

// --- raw API JSON decoding -------------------------------------------------

type rawLocationCost struct {
	HourlyCost  json.Number `json:"hourly_cost"`
	MonthlyCost json.Number `json:"monthly_cost"`
}

type rawPlan struct {
	ID           string                     `json:"id"`
	InvoiceType  string                     `json:"invoice_type"`
	HourlyCost   json.Number                `json:"hourly_cost"`
	MonthlyCost  json.Number                `json:"monthly_cost"`
	Locations    []string                   `json:"locations"`
	LocationCost map[string]rawLocationCost `json:"location_cost"`
}

func (r rawPlan) toPlan() (Plan, error) {
	hourly, err := parseMicros(r.HourlyCost)
	if err != nil {
		return Plan{}, fmt.Errorf("plan %s: hourly_cost: %w", r.ID, err)
	}
	monthly, err := parseMicros(r.MonthlyCost)
	if err != nil {
		return Plan{}, fmt.Errorf("plan %s: monthly_cost: %w", r.ID, err)
	}

	var lc map[string]LocationCost
	if len(r.LocationCost) > 0 {
		lc = make(map[string]LocationCost, len(r.LocationCost))
		for region, v := range r.LocationCost {
			h, err := parseMicros(v.HourlyCost)
			if err != nil {
				return Plan{}, fmt.Errorf("plan %s: location_cost[%s].hourly_cost: %w", r.ID, region, err)
			}
			m, err := parseMicros(v.MonthlyCost)
			if err != nil {
				return Plan{}, fmt.Errorf("plan %s: location_cost[%s].monthly_cost: %w", r.ID, region, err)
			}
			lc[region] = LocationCost{HourlyMicros: h, MonthlyMicros: m}
		}
	}

	return Plan{
		ID:            r.ID,
		InvoiceType:   r.InvoiceType,
		HourlyMicros:  hourly,
		MonthlyMicros: monthly,
		Locations:     r.Locations,
		LocationCost:  lc,
	}, nil
}

// parseMicros converts a JSON number -- decoded via json.Number, never
// float64 -- into whole millionths of a dollar via big.Rat, so e.g. 0.153
// becomes exactly 153000 rather than a binary-float approximation that would
// make golden test files flap. Duplicated, deliberately, in
// pricing/money.go's ParseMicros: pricing imports this package (Charge takes
// a vultr.Plan), so this package importing pricing back for ten lines of
// arithmetic would be a cycle.
func parseMicros(n json.Number) (int64, error) {
	s := n.String()
	if s == "" {
		s = "0"
	}
	r, ok := new(big.Rat).SetString(s)
	if !ok {
		return 0, fmt.Errorf("not a decimal number: %q", s)
	}
	r.Mul(r, big.NewRat(1_000_000, 1))
	r.Add(r, big.NewRat(1, 2)) // round half up; every input here is non-negative
	q := new(big.Int).Quo(r.Num(), r.Denom())
	return q.Int64(), nil
}
