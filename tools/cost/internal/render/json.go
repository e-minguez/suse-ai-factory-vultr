package render

import (
	"encoding/json"
	"io"

	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/tfconfig"
)

type jsonCatalog struct {
	Source string `json:"source"`
	AsOf   string `json:"as_of,omitempty"`
	Age    string `json:"age,omitempty"`
}

type jsonResource struct {
	Resource    string             `json:"resource"`
	Pool        string             `json:"pool,omitempty"`
	PlanID      string             `json:"plan_id,omitempty"`
	Qty         int                `json:"qty"`
	PlanFound   bool               `json:"plan_found"`
	InvoiceType string             `json:"invoice_type,omitempty"`
	HourlyUSD   float64            `json:"hourly_usd"`
	MonthlyUSD  float64            `json:"monthly_usd,omitempty"`
	Regional    bool               `json:"regional"`
	CostsUSD    map[string]float64 `json:"costs_usd"`
	Capped      map[string]bool    `json:"capped"`
	Warnings    []string           `json:"warnings,omitempty"`
}

type jsonRecurringAfterDestroy struct {
	// SnapshotStorageUSDPerMonth is what keeps billing after `terraform
	// destroy` -- the snapshot is not a Terraform resource (see
	// pricing.Expand's SurvivesDestroy comment), so destroying everything
	// else does not stop this charge.
	SnapshotStorageUSDPerMonth float64 `json:"snapshot_storage_usd_per_month"`
}

type jsonReport struct {
	Region                string                    `json:"region"`
	ClusterName           string                    `json:"cluster_name"`
	Catalog               jsonCatalog               `json:"catalog"`
	Durations             []string                  `json:"durations"`
	Resources             []jsonResource            `json:"resources"`
	TotalsUSD             map[string]float64        `json:"totals_usd"`
	RecurringAfterDestroy jsonRecurringAfterDestroy `json:"recurring_after_destroy"`
	Incomplete            bool                      `json:"incomplete"`
	Warnings              []string                  `json:"warnings"`
}

// JSON renders result as a single, self-contained JSON object: every warning
// the text renderer would print to stderr is also in the top-level
// "warnings" array here, per the plan's error-handling table ("Warnings go
// to stderr *and* into the JSON warnings array so --json output is
// self-contained").
func JSON(w io.Writer, cfg tfconfig.Config, result pricing.PriceResult, durations []pricing.Duration, catalog CatalogInfo) error {
	report := jsonReport{
		Region:                cfg.Region,
		ClusterName:           cfg.ClusterName,
		Catalog:               jsonCatalog{Source: catalog.Source, AsOf: catalog.AsOf, Age: catalog.Age},
		TotalsUSD:             map[string]float64{},
		RecurringAfterDestroy: jsonRecurringAfterDestroy{SnapshotStorageUSDPerMonth: result.RecurringAfterDestroy.Dollars()},
		Incomplete:            result.Incomplete,
		Warnings:              result.AllWarnings(),
	}
	if report.Warnings == nil {
		report.Warnings = []string{}
	}
	for _, d := range durations {
		report.Durations = append(report.Durations, d.Label)
		report.TotalsUSD[d.Label] = result.Totals[d.Label].Dollars()
	}
	for _, item := range result.Items {
		jr := jsonResource{
			Resource:    item.Resource.Label,
			Pool:        item.Resource.Pool,
			PlanID:      item.Resource.PlanID,
			Qty:         item.Resource.Qty,
			PlanFound:   item.PlanFound || item.Resource.Kind != pricing.KindPlan,
			InvoiceType: item.InvoiceType,
			HourlyUSD:   item.HourlyMicros.Dollars(),
			MonthlyUSD:  item.MonthlyMicros.Dollars(),
			Regional:    item.Regional,
			CostsUSD:    map[string]float64{},
			Capped:      map[string]bool{},
			Warnings:    item.Warnings,
		}
		for _, d := range durations {
			jr.CostsUSD[d.Label] = item.Costs[d.Label].Dollars()
			jr.Capped[d.Label] = item.Capped[d.Label]
		}
		report.Resources = append(report.Resources, jr)
	}

	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(report)
}
