// Command cost estimates what a terraform.tfvars for modules/ai-factory-ha
// will cost on Vultr, across 1h/8h/24h/7d/30d, without deploying anything.
// See tools/cost/README.md for usage and tools/cost/internal/* for the
// implementation this file only wires together.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/render"
	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/tfconfig"
	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/vultr"
)

// Exit codes, per the plan's error-handling table: 0 success, 2 a config
// problem (tfvars/variables.tf/flags), 3 a pricing-data problem (catalog
// unreachable, or an unknown plan at qty >= 1).
const (
	exitOK     = 0
	exitConfig = 2
	exitPrice  = 3
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("cost", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() {
		fmt.Fprintln(stderr, "usage: cost [flags] terraform.tfvars")
		fs.PrintDefaults()
	}

	defaultsPath := fs.String("defaults", "", "path to modules/ai-factory-ha/variables.tf (default: walk up from the tfvars' directory)")
	regionFlag := fs.String("region", "", "override the region (required if the tfvars doesn't set one)")
	jsonOut := fs.Bool("json", false, "print a self-contained JSON report instead of a table")
	plansFile := fs.String("plans", "", "load the plan catalog from this file instead of the network (see internal/vultr/testdata for the expected shape)")
	noNetwork := fs.Bool("no-network", false, "never call the live Vultr API; use --plans or a warm cache")
	allowUnknownPlans := fs.Bool("allow-unknown-plans", false, "price an unrecognised plan ID as $0 with a warning, instead of failing")
	durationsFlag := fs.String("durations", "1h,8h,24h,7d,30d", "comma-separated durations to price (h and d units)")

	if err := fs.Parse(args); err != nil {
		return exitConfig
	}
	if fs.NArg() != 1 {
		fs.Usage()
		return exitConfig
	}
	tfvarsPath := fs.Arg(0)

	durations, err := pricing.ParseDurations(*durationsFlag)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return exitConfig
	}

	// --- variables.tf: unreadable is a WARNING, not fatal -- see the plan's
	// error-handling table. Every variable Resolve can't then find a default
	// for becomes its own fatal error below.
	varsPath := *defaultsPath
	if varsPath == "" {
		varsPath = findVariablesTF(tfvarsPath)
	}
	decls := map[string]*tfconfig.VariableDecl{}
	var diags []tfconfig.Diagnostic
	if varsPath == "" {
		diags = append(diags, tfconfig.Diagnostic{Severity: tfconfig.SeverityWarning, Summary: "could not locate modules/ai-factory-ha/variables.tf; pass --defaults. Proceeding with built-in defaults for every variable the tfvars does not set"})
	} else if parsed, hclDiags := tfconfig.ParseVariables(varsPath); hclDiags.HasErrors() {
		for _, d := range tfconfig.FromHCLDiagnostics(hclDiags, "") {
			d.Severity = tfconfig.SeverityWarning // unreadable variables.tf is a warning, not fatal
			diags = append(diags, d)
		}
	} else {
		decls = parsed
		diags = append(diags, tfconfig.FromHCLDiagnostics(hclDiags, "")...)
	}

	// --- tfvars: unparseable IS fatal. Detail is dropped for any diagnostic
	// whose Subject falls inside this file -- see tfconfig.FromHCLDiagnostics.
	tfvars, hclDiags := tfconfig.ParseTFVars(tfvarsPath)
	if hclDiags.HasErrors() {
		for _, d := range tfconfig.FromHCLDiagnostics(hclDiags, tfvarsPath) {
			fmt.Fprintln(stderr, d.Format())
		}
		return exitConfig
	}
	diags = append(diags, tfconfig.FromHCLDiagnostics(hclDiags, tfvarsPath)...)

	overrides := map[string]string{}
	if *regionFlag != "" {
		overrides["region"] = *regionFlag
	}

	cfg, resolveDiags := tfconfig.Resolve(decls, tfvars, overrides)
	diags = append(diags, resolveDiags...)

	if tfconfig.HasErrors(diags) {
		for _, d := range diags {
			fmt.Fprintln(stderr, d.Format())
		}
		return exitConfig
	}

	var warnings []string
	for _, d := range diags {
		fmt.Fprintln(stderr, "warning: "+d.Format())
		warnings = append(warnings, d.Format())
	}

	// --- plan catalog ---
	catalog, catalogInfo, catErr := loadCatalog(*plansFile, *noNetwork, stderr)
	if catErr != nil {
		fmt.Fprintln(stderr, catErr)
		return exitPrice
	}

	resources := pricing.Expand(cfg)
	result, priceErr := pricing.Price(resources, catalog, cfg.Region, durations, *allowUnknownPlans)
	result.Warnings = append(result.Warnings, warnings...)
	if priceErr != nil {
		for _, w := range result.AllWarnings() {
			fmt.Fprintln(stderr, "warning: "+w)
		}
		fmt.Fprintln(stderr, priceErr)
		return exitPrice
	}

	var renderErr error
	if *jsonOut {
		renderErr = render.JSON(stdout, cfg, result, durations, catalogInfo)
	} else {
		renderErr = render.Text(stdout, cfg, result, durations, catalogInfo)
	}
	if renderErr != nil {
		fmt.Fprintln(stderr, renderErr)
		return exitPrice
	}

	return exitOK
}

// findVariablesTF walks up from the tfvars' own directory looking for
// modules/ai-factory-ha/variables.tf, matching how examples/ha-cluster (and
// any sibling example) sits two directories below the repo root.
func findVariablesTF(tfvarsPath string) string {
	dir, err := filepath.Abs(filepath.Dir(tfvarsPath))
	if err != nil {
		return ""
	}
	for {
		candidate := filepath.Join(dir, "modules", "ai-factory-ha", "variables.tf")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// loadCatalog implements the plan's catalog-resolution rows: --plans wins
// outright; otherwise a live fetch is attempted unless --no-network, falling
// back to a warm on-disk cache on failure (warning, with the cache's age),
// and only failing outright (exit 3) when none of --plans, the network, or a
// cache produced anything.
func loadCatalog(plansFile string, noNetwork bool, stderr io.Writer) (vultr.Catalog, render.CatalogInfo, error) {
	if plansFile != "" {
		catalog, err := vultr.LoadPlansFile(plansFile)
		if err != nil {
			return nil, render.CatalogInfo{}, fmt.Errorf("loading --plans %s: %w", plansFile, err)
		}
		return catalog, render.CatalogInfo{Source: "file"}, nil
	}

	cachePath, cacheErr := vultr.DefaultCachePath()

	if noNetwork {
		if cacheErr == nil {
			if catalog, fetchedAt, err := vultr.LoadCache(cachePath); err == nil {
				age := time.Since(fetchedAt).Round(time.Minute)
				return catalog, render.CatalogInfo{Source: "cache", AsOf: fetchedAt.UTC().Format(time.RFC3339), Age: fmt.Sprintf("(%s old)", age)}, nil
			}
		}
		return nil, render.CatalogInfo{}, fmt.Errorf("--no-network was set, no --plans given, and no warm cache is available at %s", cachePath)
	}

	fetchedAt := time.Now()
	catalog, err := vultr.FetchLive(context.Background(), http.DefaultClient, 15*time.Second)
	if err == nil {
		if cacheErr == nil {
			if saveErr := vultr.SaveCache(cachePath, catalog, fetchedAt); saveErr != nil {
				fmt.Fprintf(stderr, "warning: could not save plan catalog cache: %v\n", saveErr)
			}
		}
		return catalog, render.CatalogInfo{Source: "api", AsOf: fetchedAt.UTC().Format(time.RFC3339)}, nil
	}

	if cacheErr == nil {
		if catalog, cachedAt, cErr := vultr.LoadCache(cachePath); cErr == nil {
			age := time.Since(cachedAt).Round(time.Minute)
			fmt.Fprintf(stderr, "warning: fetching the live plan catalog failed (%v); using cached catalog from %s\n", err, cachedAt.UTC().Format(time.RFC3339))
			return catalog, render.CatalogInfo{Source: "cache", AsOf: cachedAt.UTC().Format(time.RFC3339), Age: fmt.Sprintf("(%s old, network unavailable)", age)}, nil
		}
	}

	return nil, render.CatalogInfo{}, fmt.Errorf("fetching the live plan catalog failed and no cache or --plans is available: %w", err)
}
