package tfconfig

import (
	"reflect"
	"testing"

	"github.com/zclconf/go-cty/cty"
	"github.com/zclconf/go-cty/cty/gocty"
)

// realModuleVariables is modules/ai-factory-ha/variables.tf's own path,
// relative to this package's directory.
const realModuleVariables = "../../../../modules/ai-factory-ha/variables.tf"

// exampleVariables is examples/ha-cluster/variables.tf's own path, which is
// meant to duplicate every pricing-relevant default from the module above.
const exampleVariables = "../../../../examples/ha-cluster/variables.tf"

// TestParsesRealModuleVariables is the highest-value test in this package:
// it exercises the actual 44 KB production variables.tf -- its brace-in-regex
// validations (variables.tf:283, :306ish, :322, :374) and its two top-level
// check blocks (:494, :606) -- on every `go test`, with zero diagnostics
// expected.
func TestParsesRealModuleVariables(t *testing.T) {
	decls, diags := ParseVariables(realModuleVariables)
	if diags.HasErrors() {
		t.Fatalf("unexpected diagnostics parsing %s: %s", realModuleVariables, diags.Error())
	}

	region, ok := decls["region"]
	if !ok {
		t.Fatal("variable \"region\" not found")
	}
	if region.HasDefault {
		t.Error("variable \"region\" should have no default (variables.tf:1)")
	}

	wantString := map[string]string{
		"control_plane_plan": "vx1-g-4c-16g-240s",
		"jumphost_plan":      "vc2-6c-16gb",
		"ingress_controller": "traefik",
		"image_disk_size":    "8G",
	}
	for name, want := range wantString {
		decl, ok := decls[name]
		if !ok {
			t.Errorf("variable %q not found", name)
			continue
		}
		if !decl.HasDefault {
			t.Errorf("variable %q: expected a default", name)
			continue
		}
		got, err := ctyToString(decl.Default)
		if err != nil {
			t.Errorf("variable %q: %v", name, err)
			continue
		}
		if got != want {
			t.Errorf("variable %q default = %q, want %q", name, got, want)
		}
	}

	wantNumber := map[string]int{
		"control_plane_count": 3,
		"lb_nodes":            1,
	}
	for name, want := range wantNumber {
		decl, ok := decls[name]
		if !ok {
			t.Errorf("variable %q not found", name)
			continue
		}
		got, err := ctyToInt(decl.Default)
		if err != nil {
			t.Errorf("variable %q: %v", name, err)
			continue
		}
		if got != want {
			t.Errorf("variable %q default = %d, want %d", name, got, want)
		}
	}

	deployNodes, ok := decls["deploy_nodes"]
	if !ok {
		t.Fatal("variable \"deploy_nodes\" not found")
	}
	if !deployNodes.HasDefault || deployNodes.Default.False() {
		t.Error("variable \"deploy_nodes\" should default to true")
	}

	for _, name := range []string{"gpu_bare_metal_pools", "gpu_cloud_pools"} {
		decl, ok := decls[name]
		if !ok {
			t.Errorf("variable %q not found", name)
			continue
		}
		if !decl.HasDefault {
			t.Errorf("variable %q: expected a default", name)
			continue
		}
		if decl.Default.LengthInt() != 0 {
			t.Errorf("variable %q default should be empty, got %#v", name, decl.Default)
		}
	}
}

// TestExampleDefaultsMatchModule parses both variables.tf files and asserts
// that resolving the same (empty) tfvars against each produces the same
// Config, aside from Region (supplied only via override, since neither file
// gives it a default). Drift here would make --defaults silently wrong for
// anyone running this tool against the example.
func TestExampleDefaultsMatchModule(t *testing.T) {
	moduleDecls, diags := ParseVariables(realModuleVariables)
	if diags.HasErrors() {
		t.Fatalf("parsing %s: %s", realModuleVariables, diags.Error())
	}
	exampleDecls, diags := ParseVariables(exampleVariables)
	if diags.HasErrors() {
		t.Fatalf("parsing %s: %s", exampleVariables, diags.Error())
	}

	overrides := map[string]string{"region": "ams"}
	moduleCfg, diags1 := Resolve(moduleDecls, map[string]TFVarValue{}, overrides)
	if HasErrors(diags1) {
		t.Fatalf("resolving module defaults: %v", diags1)
	}
	exampleCfg, diags2 := Resolve(exampleDecls, map[string]TFVarValue{}, overrides)
	if HasErrors(diags2) {
		t.Fatalf("resolving example defaults: %v", diags2)
	}

	if !reflect.DeepEqual(moduleCfg, exampleCfg) {
		t.Errorf("example defaults drifted from the module's own defaults:\n  module:  %+v\n  example: %+v", moduleCfg, exampleCfg)
	}
}

// TestParsesSyntheticVariablesFixture proves a heredoc description and a
// top-level check block are both handled without error or evaluation.
func TestParsesSyntheticVariablesFixture(t *testing.T) {
	decls, diags := ParseVariables("testdata/synthetic_variables.tf")
	if diags.HasErrors() {
		t.Fatalf("unexpected diagnostics: %s", diags.Error())
	}
	if _, ok := decls["region"]; !ok {
		t.Error("expected variable \"region\" to parse despite its heredoc description")
	}
	widgets, ok := decls["widgets"]
	if !ok {
		t.Fatal("expected variable \"widgets\" to parse")
	}
	if widgets.Defaults == nil {
		t.Error("expected widgets' type expression to carry optional() defaults")
	}
}

func ctyToString(v cty.Value) (string, error) {
	var s string
	err := gocty.FromCtyValue(v, &s)
	return s, err
}

func ctyToInt(v cty.Value) (int, error) {
	var n int
	err := gocty.FromCtyValue(v, &n)
	return n, err
}
