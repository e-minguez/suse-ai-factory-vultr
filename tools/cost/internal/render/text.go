// Package render turns a priced report into the CLI's two output formats:
// a human-readable table (text.go) and a self-contained JSON document
// (json.go).
package render

import (
	"fmt"
	"io"
	"math"
	"text/tabwriter"

	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/tfconfig"
)

// CatalogInfo describes where the plan catalog came from, for the header
// line (text) and the "catalog" object (JSON).
type CatalogInfo struct {
	Source string // "api", "cache", or "file"
	AsOf   string // RFC3339 fetch time, or "" if unknown
	Age    string // human-readable staleness note, e.g. "(3h old, network unavailable)"; "" when fresh
}

// Text renders result as the default human-readable table: one row per
// pricing.Resource in the order pricing.Expand produced them, a TOTAL row,
// and footnotes for the monthly cap, the snapshot's post-destroy cost, and
// this tool's fixed exclusions.
func Text(w io.Writer, cfg tfconfig.Config, result pricing.PriceResult, durations []pricing.Duration, catalog CatalogInfo) error {
	catalogDesc := catalog.Source
	if catalog.AsOf != "" {
		catalogDesc += " (" + catalog.AsOf + ")"
	}
	if catalog.Age != "" {
		catalogDesc += " " + catalog.Age
	}
	fmt.Fprintf(w, "Region: %s   Cluster: %s   Catalog: %s\n\n", cfg.Region, cfg.ClusterName, catalogDesc)

	tw := tabwriter.NewWriter(w, 0, 4, 2, ' ', tabwriter.AlignRight)

	// tabwriter's AlignRight is per-Writer, not per-column, and right-aligning
	// the resource names reads badly against a column of numbers. Pre-padding
	// every cell in that one column to a common width makes right and left
	// alignment identical for it, which is the only way to mix the two.
	labelWidth := len("RESOURCE")
	for _, item := range result.Items {
		if n := len(resourceLabel(item)); n > labelWidth {
			labelWidth = n
		}
	}
	pad := func(s string) string { return fmt.Sprintf("%-*s", labelWidth, s) }

	fmt.Fprintf(tw, "%s\tQTY\tPLAN\t$/hr", pad("RESOURCE"))
	for _, d := range durations {
		fmt.Fprintf(tw, "\t%s", d.Label)
	}
	// tabwriter formats columns as TAB-TERMINATED, not tab-separated: without
	// a trailing tab here the last column on every line is left unformatted
	// and runs straight into the next line's last column with no gap.
	fmt.Fprint(tw, "\t\n")

	anyCapped := false
	anyRegional := false
	for _, item := range result.Items {
		if item.Regional {
			anyRegional = true
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s", pad(resourceLabel(item)), qtyCell(item), planCell(item), hourlyCell(item))
		for _, d := range durations {
			cell, capped := costCell(item, d)
			if capped {
				anyCapped = true
			}
			fmt.Fprintf(tw, "\t%s", cell)
		}
		fmt.Fprint(tw, "\t\n")
	}

	fmt.Fprintf(tw, "%s\t\t\tTOTAL", pad(""))
	for _, d := range durations {
		fmt.Fprintf(tw, "\t%s", formatDollars(result.Totals[d.Label]))
	}
	fmt.Fprint(tw, "\t\n")

	if err := tw.Flush(); err != nil {
		return err
	}

	fmt.Fprintln(w)
	if anyCapped {
		fmt.Fprintln(w, "  *  capped at the plan's monthly rate")
	}
	if anyRegional {
		fmt.Fprintf(w, "  Pricing includes a location_cost override for region %q.\n", cfg.Region)
	}
	fmt.Fprintf(w, "  Snapshot storage continues at $%s/month after `terraform destroy`.\n", formatDollars(result.RecurringAfterDestroy))
	fmt.Fprintln(w, "  Excludes bandwidth overage, auto-backups, reserved IPs and DDoS protection.")
	if result.Incomplete {
		fmt.Fprintln(w, "  TOTAL is a floor, not a full total: at least one plan was not found in the catalog (--allow-unknown-plans).")
	}

	for _, warn := range result.AllWarnings() {
		fmt.Fprintf(w, "  warning: %s\n", warn)
	}

	return nil
}

// formatDollars renders m to the cent, via integer arithmetic on the raw
// Micros value -- never through a float64 dollar figure. m.Dollars() exists
// for callers that genuinely want a float (JSON output); the text table
// does not, because e.g. 15_000 micros ($0.015) is exactly the round-half-up
// boundary, and float64(15000)/1e6 is not exactly representable as a binary
// fraction, which can round %.2f the wrong way (0.01 instead of 0.02) on
// some inputs. Integer math has no such edge case.
func formatDollars(m pricing.Micros) string {
	cents := roundToUnit(int64(m), 10_000) // 10_000 micros = $0.01
	return formatFixed(cents, 100)
}

// formatRate renders m to four decimal places (Vultr's own hourly_cost
// figures never carry more precision than that), via the same integer
// approach as formatDollars.
func formatRate(m pricing.Micros) string {
	tenThousandths := roundToUnit(int64(m), 100) // 100 micros = $0.0001
	return formatFixed(tenThousandths, 10_000)
}

// roundToUnit rounds v to the nearest multiple of unit, half away from zero,
// and returns the result already divided by unit (i.e. "how many units").
func roundToUnit(v, unit int64) int64 {
	if v < 0 {
		return -roundToUnit(-v, unit)
	}
	return (v + unit/2) / unit
}

// formatFixed renders whole as a fixed-point decimal with scale digits after
// the point (e.g. formatFixed(153, 100) -> "1.53").
func formatFixed(whole, scale int64) string {
	sign := ""
	if whole < 0 {
		sign = "-"
		whole = -whole
	}
	digits := len(fmt.Sprintf("%d", scale)) - 1
	return fmt.Sprintf("%s%d.%0*d", sign, whole/scale, digits, whole%scale)
}

func resourceLabel(item pricing.LineItem) string {
	if item.Resource.Kind == pricing.KindStorage {
		return fmt.Sprintf("%s (%s)", item.Resource.Label, formatGB(item.Resource.SizeGB))
	}
	return item.Resource.Label
}

func formatGB(gb float64) string {
	if gb == math.Trunc(gb) {
		return fmt.Sprintf("%d GB", int64(gb))
	}
	return fmt.Sprintf("%.1f GB", gb)
}

func qtyCell(item pricing.LineItem) string {
	if item.Resource.Kind == pricing.KindFree {
		return ""
	}
	return fmt.Sprintf("%d", item.Resource.Qty)
}

func planCell(item pricing.LineItem) string {
	switch item.Resource.Kind {
	case pricing.KindFixedRate, pricing.KindStorage:
		return "-- fixed --"
	case pricing.KindFree:
		return "-- free --"
	default:
		if !item.PlanFound {
			return item.Resource.PlanID + " (unknown)"
		}
		return item.Resource.PlanID
	}
}

func hourlyCell(item pricing.LineItem) string {
	if item.Resource.Kind == pricing.KindFree || item.Resource.Kind == pricing.KindStorage {
		return "--"
	}
	if item.Resource.Qty == 0 {
		return "--"
	}
	if item.Resource.Kind == pricing.KindPlan && !item.PlanFound {
		return "--"
	}
	return formatRate(item.HourlyMicros)
}

func costCell(item pricing.LineItem, d pricing.Duration) (string, bool) {
	if item.Resource.Kind == pricing.KindFree {
		return "--", false
	}
	if item.Resource.Qty == 0 {
		return "--", false
	}
	capped := item.Capped[d.Label]
	s := formatDollars(item.Costs[d.Label])
	if capped {
		s += " *"
	}
	return s, capped
}
