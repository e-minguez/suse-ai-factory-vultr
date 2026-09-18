package pricing

import (
	"testing"

	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/tfconfig"
	"github.com/e-minguez/suse-ai-factory-uc-vultr/tools/cost/internal/vultr"
)

func TestExpandControlPlaneOnly(t *testing.T) {
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
	}
	res := Expand(cfg)

	byLabel := map[string]Resource{}
	for _, r := range res {
		byLabel[r.Label] = r
	}

	if got := byLabel["jumphost"]; got.Qty != 1 || got.PlanID != "vc2-6c-16gb" {
		t.Errorf("jumphost = %+v", got)
	}
	if got := byLabel["control plane"]; got.Qty != 3 || got.PlanID != "vx1-g-4c-16g-240s" {
		t.Errorf("control plane = %+v", got)
	}
	if got := byLabel["load balancer (api)"]; got.Qty != 1 {
		t.Errorf("load balancer (api) = %+v", got)
	}
	if got := byLabel["load balancer (ingress)"]; got.Qty != 1 {
		t.Errorf("load balancer (ingress) = %+v, want qty 1 (ingress_controller=traefik)", got)
	}
	if got := byLabel["nat gateway"]; got.Qty != 1 {
		t.Errorf("nat gateway = %+v", got)
	}
	snapshot, ok := byLabel["snapshot storage"]
	if !ok || snapshot.SizeGB != 8 || !snapshot.SurvivesDestroy {
		t.Errorf("snapshot storage = %+v", snapshot)
	}
	free, ok := byLabel["vpc / firewall groups+rules"]
	if !ok || free.Kind != KindFree {
		t.Errorf("vpc / firewall groups+rules = %+v", free)
	}
}

// TestExpandIngressNoneShowsZeroQty: ingress_controller = "none" must still
// list the ingress load balancer row, at Qty 0 -- a configured-but-off
// resource stays visible rather than being omitted.
func TestExpandIngressNoneShowsZeroQty(t *testing.T) {
	cfg := tfconfig.Config{IngressController: "none", LBNodes: 1}
	res := Expand(cfg)
	for _, r := range res {
		if r.Label == "load balancer (ingress)" {
			if r.Qty != 0 {
				t.Errorf("Qty = %d, want 0", r.Qty)
			}
			return
		}
	}
	t.Error("expected a \"load balancer (ingress)\" row even when disabled")
}

// TestExpandDeployNodesFalseZeroesNodeCounts: deploy_nodes = false must zero
// control-plane and GPU pool quantities, but never remove the jumphost, LBs,
// NAT gateway, or snapshot -- deploy_nodes only gates node provisioning.
func TestExpandDeployNodesFalseZeroesNodeCounts(t *testing.T) {
	cfg := tfconfig.Config{
		DeployNodes:       false,
		ControlPlaneCount: 3,
		ControlPlanePlan:  "vx1-g-4c-16g-240s",
		JumphostPlan:      "vc2-6c-16gb",
		LBNodes:           1,
		IngressController: "traefik",
		ImageDiskGB:       8,
		BareMetalPools:    []tfconfig.BareMetalPool{{Name: "gpu", Plan: "vbm-6c-32gb-amd", Count: 2}},
	}
	res := Expand(cfg)
	for _, r := range res {
		switch r.Label {
		case "control plane", "gpu bare metal / gpu":
			if r.Qty != 0 {
				t.Errorf("%s Qty = %d, want 0 (deploy_nodes = false)", r.Label, r.Qty)
			}
		case "jumphost", "nat gateway":
			if r.Qty != 1 {
				t.Errorf("%s Qty = %d, want 1 (unaffected by deploy_nodes)", r.Label, r.Qty)
			}
		}
	}
}

func TestExpandFreeResourceAlwaysZero(t *testing.T) {
	res := Expand(tfconfig.Config{JumphostPlan: "vc2-6c-16gb"})
	found := false
	catalog := vultr.MapCatalog{
		"vc2-6c-16gb": {ID: "vc2-6c-16gb", InvoiceType: "monthly", HourlyMicros: 110_000, MonthlyMicros: 80_000_000, Locations: []string{"ams"}},
	}
	result, err := Price(res, catalog, "ams", DefaultDurations, false)
	if err != nil {
		t.Fatalf("Price: %v", err)
	}
	for _, item := range result.Items {
		if item.Resource.Kind == KindFree {
			found = true
			for _, d := range DefaultDurations {
				if item.Costs[d.Label] != 0 {
					t.Errorf("free resource cost at %s = %d, want 0", d.Label, item.Costs[d.Label])
				}
			}
		}
	}
	if !found {
		t.Fatal("expected a KindFree resource")
	}
}
