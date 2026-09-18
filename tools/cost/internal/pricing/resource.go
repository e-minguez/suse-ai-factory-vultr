package pricing

import "github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/tfconfig"

// Kind distinguishes how a Resource is priced.
type Kind int

const (
	// KindPlan is priced by looking PlanID up in a vultr.Catalog.
	KindPlan Kind = iota
	// KindFixedRate is priced against one of rates.go's hardcoded LB/NAT
	// constants, via Resource.FixedRate.
	KindFixedRate
	// KindStorage is priced by ProrateSnapshot against Resource.SizeGB.
	KindStorage
	// KindFree is always $0 across every duration, but still a row: see the
	// plan's Output section on why free resources are listed, not omitted.
	KindFree
)

// Resource is one row of the eventual cost table -- a billable (or
// deliberately-free) thing the module's Terraform would create -- before any
// catalog lookup. pricing.Price turns a []Resource into []LineItem.
type Resource struct {
	Kind  Kind
	Label string // rendered resource name, e.g. "control plane", "gpu bare metal / gpu"
	Pool  string // pool key; "" when the resource isn't pool-based

	PlanID string // catalog plan ID; meaningless for KindStorage/KindFree
	Qty    int    // 0 is rendered, not omitted -- a configured-but-off pool stays visible

	SizeGB float64 // KindStorage only

	FixedRate Rate // KindFixedRate only

	// SurvivesDestroy marks the one resource (the snapshot) `terraform
	// destroy` does not remove -- image-factory.sh.tftpl:430 -- so
	// pricing.Price can add it to PriceResult.RecurringAfterDestroy.
	SurvivesDestroy bool
}

// Expand mirrors the module's own resource inventory -- locals.tf:176-224's
// node flattening and network.tf:15-171's load balancer/NAT gateway/VPC/
// firewall resources -- turning a resolved Config into the flat list of
// billable (and free) things pricing.Price prices.
//
// Every citation below is to modules/ai-factory-ha, confirmed against the
// live source, not merely against the plan that describes this tool.
func Expand(cfg tfconfig.Config) []Resource {
	var res []Resource

	// jumphost.tf:57 -- always exactly one, independent of deploy_nodes: the
	// jumphost is also the image factory, so it exists even for a
	// deploy_nodes=false, network-and-jumphost-only apply.
	res = append(res, Resource{Kind: KindPlan, Label: "jumphost", PlanID: cfg.JumphostPlan, Qty: 1})

	// control-plane.tf:6 -- count = deploy_nodes ? control_plane_count : 0.
	cpQty := 0
	if cfg.DeployNodes {
		cpQty = cfg.ControlPlaneCount
	}
	res = append(res, Resource{Kind: KindPlan, Label: "control plane", PlanID: cfg.ControlPlanePlan, Qty: cpQty})

	// gpu-nodes.tf:17 -- one row per configured pool, gated on deploy_nodes,
	// shown even at Qty 0 (locals.tf:176 sorts pool keys; Config.BareMetalPools
	// already carries that order from tfconfig.decodeBareMetalPools).
	for _, p := range cfg.BareMetalPools {
		qty := 0
		if cfg.DeployNodes {
			qty = p.Count
		}
		res = append(res, Resource{Kind: KindPlan, Label: "gpu bare metal / " + p.Name, Pool: p.Name, PlanID: p.Plan, Qty: qty})
	}

	// gpu-nodes.tf:53
	for _, p := range cfg.CloudPools {
		qty := 0
		if cfg.DeployNodes {
			qty = p.Count
		}
		res = append(res, Resource{Kind: KindPlan, Label: "gpu cloud / " + p.Name, Pool: p.Name, PlanID: p.Plan, Qty: qty})
	}

	lbRate := Rate{HourlyMicros: LBHourlyMicros, MonthlyMicros: LBMonthlyCapMicros}

	// network.tf:25 -- always 1 load balancer, nodes = lb_nodes.
	res = append(res, Resource{Kind: KindFixedRate, Label: "load balancer (api)", Qty: cfg.LBNodes, FixedRate: lbRate})

	// network.tf:124 -- count = ingress_controller == "none" ? 0 : 1, nodes =
	// lb_nodes. Shown at Qty 0 rather than omitted when ingress is disabled.
	ingressQty := cfg.LBNodes
	if cfg.IngressController == "none" {
		ingressQty = 0
	}
	res = append(res, Resource{Kind: KindFixedRate, Label: "load balancer (ingress)", Qty: ingressQty, FixedRate: lbRate})

	// network.tf:15 -- always 1.
	res = append(res, Resource{
		Kind: KindFixedRate, Label: "nat gateway", Qty: 1,
		FixedRate: Rate{HourlyMicros: NATHourlyMicros, MonthlyMicros: NATMonthlyCapMicros},
	})

	// NOT a Terraform resource: built out-of-band by the jumphost's
	// image-factory.sh.tftpl via the Vultr API, and only read back by a data
	// source. Always exactly one, sized from image_disk_size -- Vultr bills
	// the imported snapshot's actual (smaller) size, so this is a ceiling,
	// not the real figure (see the README's Known limits). The one line item
	// that survives `terraform destroy`.
	res = append(res, Resource{Kind: KindStorage, Label: "snapshot storage", Qty: 1, SizeGB: cfg.ImageDiskGB, SurvivesDestroy: true})

	// Free, but listed rather than omitted so the reader sees they were
	// considered: network.tf:4's vultr_vpc, and firewall.tf's three
	// vultr_firewall_group plus roughly two dozen vultr_firewall_rule.
	// Vultr charges nothing for either resource type.
	res = append(res, Resource{Kind: KindFree, Label: "vpc / firewall groups+rules", Qty: 1})

	return res
}
