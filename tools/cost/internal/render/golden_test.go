package render

import (
	"bytes"
	"flag"
	"os"
	"path/filepath"
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/tfconfig"
	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/vultr"
)

var update = flag.Bool("update", false, "write golden files instead of comparing against them")

func fixtureConfigAndCatalog() (tfconfig.Config, vultr.MapCatalog) {
	cfg := tfconfig.Config{
		Region:            "ams",
		ClusterName:       "suse-ai-factory",
		DeployNodes:       true,
		ControlPlaneCount: 3,
		ControlPlanePlan:  "vx1-g-4c-16g-240s",
		JumphostPlan:      "vc2-6c-16gb",
		LBNodes:           1,
		IngressController: "traefik",
		ImageDiskGB:       8,
		CloudPools: []tfconfig.CloudPool{
			{Name: "cgpu", Plan: "voc-c-4c-8gb-150s-amd", Count: 1, VPCOnly: false},
		},
		BareMetalPools: []tfconfig.BareMetalPool{
			{Name: "gpu", Plan: "vbm-6c-32gb-amd", Count: 0},
		},
	}
	catalog := vultr.MapCatalog{
		"vc2-6c-16gb":           {ID: "vc2-6c-16gb", InvoiceType: "monthly", HourlyMicros: 110_000, MonthlyMicros: 80_000_000, Locations: []string{"ams"}},
		"vx1-g-4c-16g-240s":     {ID: "vx1-g-4c-16g-240s", InvoiceType: "hourly", HourlyMicros: 153_000, MonthlyMicros: 111_690_000, Locations: []string{"ams"}},
		"voc-c-4c-8gb-150s-amd": {ID: "voc-c-4c-8gb-150s-amd", InvoiceType: "monthly", HourlyMicros: 123_000, MonthlyMicros: 90_000_000, Locations: []string{"ams"}},
		"vbm-6c-32gb-amd":       {ID: "vbm-6c-32gb-amd", InvoiceType: "monthly", HourlyMicros: 410_000, MonthlyMicros: 295_000_000, Locations: []string{"ams"}},
	}
	return cfg, catalog
}

func priceFixture(t *testing.T) (tfconfig.Config, pricing.PriceResult) {
	t.Helper()
	cfg, catalog := fixtureConfigAndCatalog()
	resources := pricing.Expand(cfg)
	result, err := pricing.Price(resources, catalog, cfg.Region, pricing.DefaultDurations, false)
	if err != nil {
		t.Fatalf("pricing.Price: %v", err)
	}
	return cfg, result
}

func compareGolden(t *testing.T, path string, got []byte) {
	t.Helper()
	if *update {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading golden file %s: %v (run `go test ./... -update` to create it)", path, err)
	}
	if diff := cmp.Diff(string(want), string(got)); diff != "" {
		t.Errorf("%s mismatch (-want +got):\n%s", path, diff)
	}
}

func TestTextGolden(t *testing.T) {
	cfg, result := priceFixture(t)
	var buf bytes.Buffer
	catalogInfo := CatalogInfo{Source: "file"}
	if err := Text(&buf, cfg, result, pricing.DefaultDurations, catalogInfo); err != nil {
		t.Fatalf("Text: %v", err)
	}
	compareGolden(t, "testdata/golden/text.txt", buf.Bytes())
}

func TestJSONGolden(t *testing.T) {
	cfg, result := priceFixture(t)
	var buf bytes.Buffer
	catalogInfo := CatalogInfo{Source: "file"}
	if err := JSON(&buf, cfg, result, pricing.DefaultDurations, catalogInfo); err != nil {
		t.Fatalf("JSON: %v", err)
	}
	compareGolden(t, "testdata/golden/report.json", buf.Bytes())
}
