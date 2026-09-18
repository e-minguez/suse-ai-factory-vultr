package pricing

import (
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/vultr"
)

func fakeCatalog() vultr.MapCatalog {
	return vultr.MapCatalog{
		"vc2-6c-16gb": {ID: "vc2-6c-16gb", InvoiceType: "monthly", HourlyMicros: 110_000, MonthlyMicros: 80_000_000, Locations: []string{"ams"}},
	}
}

// TestPriceUnknownPlanQtyGEQ1Fatal: a referenced plan ID absent from the
// catalog at Qty >= 1 must fail Price outright, unless allowUnknownPlans.
func TestPriceUnknownPlanQtyGEQ1Fatal(t *testing.T) {
	resources := []Resource{{Kind: KindPlan, Label: "control plane", PlanID: "does-not-exist", Qty: 1}}
	_, err := Price(resources, fakeCatalog(), "ams", DefaultDurations, false)
	if err == nil {
		t.Fatal("expected an error for an unknown plan at qty >= 1")
	}
	if !strings.Contains(err.Error(), "does-not-exist") {
		t.Errorf("error should name the plan ID, got: %v", err)
	}
}

// TestPriceUnknownPlanAllowed: --allow-unknown-plans downgrades the same
// condition to a warning and marks the result Incomplete.
func TestPriceUnknownPlanAllowed(t *testing.T) {
	resources := []Resource{{Kind: KindPlan, Label: "control plane", PlanID: "does-not-exist", Qty: 1}}
	result, err := Price(resources, fakeCatalog(), "ams", DefaultDurations, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.Incomplete {
		t.Error("expected Incomplete = true")
	}
	if result.Totals["1h"] != 0 {
		t.Errorf("unknown plan should price as $0, got total %d", result.Totals["1h"])
	}
}

// TestPriceUnknownPlanQtyZeroWarnsOnly: an unknown plan at Qty 0 is
// informational, never fatal, regardless of allowUnknownPlans.
func TestPriceUnknownPlanQtyZeroWarnsOnly(t *testing.T) {
	resources := []Resource{{Kind: KindPlan, Label: "gpu bare metal / off", PlanID: "does-not-exist", Qty: 0}}
	result, err := Price(resources, fakeCatalog(), "ams", DefaultDurations, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Incomplete {
		t.Error("Qty 0 should not mark the result Incomplete")
	}
	if len(result.Items) != 1 || len(result.Items[0].Warnings) == 0 {
		t.Error("expected an informational warning on the line item")
	}
}

// TestPriceRegionNotInLocationsWarnsNotFails: a plan whose Locations don't
// list the requested region is priced anyway, with a warning -- the
// unauthenticated catalog is documented to under-report availability.
func TestPriceRegionNotInLocationsWarnsNotFails(t *testing.T) {
	catalog := vultr.MapCatalog{
		"vc2-6c-16gb": {ID: "vc2-6c-16gb", InvoiceType: "monthly", HourlyMicros: 110_000, MonthlyMicros: 80_000_000, Locations: []string{"ewr"}},
	}
	resources := []Resource{{Kind: KindPlan, Label: "jumphost", PlanID: "vc2-6c-16gb", Qty: 1}}
	result, err := Price(resources, catalog, "ams", DefaultDurations, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Totals["1h"] == 0 {
		t.Error("expected a non-zero price even though the region isn't in Locations")
	}
	if len(result.Items[0].Warnings) == 0 {
		t.Error("expected a warning about the region not being in Locations")
	}
}

// TestPriceRegionalOverrideApplied asserts location_cost overrides both the
// hourly and monthly figures used for billing.
func TestPriceRegionalOverrideApplied(t *testing.T) {
	catalog := vultr.MapCatalog{
		"vc2-6c-16gb": {
			ID: "vc2-6c-16gb", InvoiceType: "monthly",
			HourlyMicros: 110_000, MonthlyMicros: 80_000_000,
			Locations:    []string{"sao"},
			LocationCost: map[string]vultr.LocationCost{"sao": {HourlyMicros: 164_000, MonthlyMicros: 120_000_000}},
		},
	}
	resources := []Resource{{Kind: KindPlan, Label: "jumphost", PlanID: "vc2-6c-16gb", Qty: 1}}
	result, err := Price(resources, catalog, "sao", DefaultDurations, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	item := result.Items[0]
	if !item.Regional {
		t.Error("expected Regional = true")
	}
	if item.HourlyMicros != 164_000 {
		t.Errorf("HourlyMicros = %d, want 164000 (the sao override)", item.HourlyMicros)
	}
}
