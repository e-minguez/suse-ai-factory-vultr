package tfconfig

import (
	"testing"

	"github.com/zclconf/go-cty/cty"
)

func mustParseVariables(t *testing.T, path string) map[string]*VariableDecl {
	t.Helper()
	decls, diags := ParseVariables(path)
	if diags.HasErrors() {
		t.Fatalf("parsing %s: %s", path, diags.Error())
	}
	return decls
}

func mustParseTFVars(t *testing.T, path string) map[string]TFVarValue {
	t.Helper()
	vals, diags := ParseTFVars(path)
	if diags.HasErrors() {
		t.Fatalf("parsing %s: %s", path, diags.Error())
	}
	return vals
}

// TestResolveMinimalDefaults asserts that a tfvars setting only `region`
// resolves every other pricing-relevant field to the real module's shipped
// default.
func TestResolveMinimalDefaults(t *testing.T) {
	decls := mustParseVariables(t, realModuleVariables)
	tfvars := mustParseTFVars(t, "testdata/minimal.tfvars")

	cfg, diags := Resolve(decls, tfvars, nil)
	if HasErrors(diags) {
		t.Fatalf("unexpected errors: %v", diags)
	}

	want := Config{
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
	if cfg.Region != want.Region ||
		cfg.ClusterName != want.ClusterName ||
		cfg.DeployNodes != want.DeployNodes ||
		cfg.ControlPlaneCount != want.ControlPlaneCount ||
		cfg.ControlPlanePlan != want.ControlPlanePlan ||
		cfg.JumphostPlan != want.JumphostPlan ||
		cfg.LBNodes != want.LBNodes ||
		cfg.IngressController != want.IngressController ||
		cfg.ImageDiskGB != want.ImageDiskGB {
		t.Errorf("got %+v, want %+v", cfg, want)
	}
	if len(cfg.BareMetalPools) != 0 {
		t.Errorf("BareMetalPools = %+v, want empty", cfg.BareMetalPools)
	}
	if len(cfg.CloudPools) != 0 {
		t.Errorf("CloudPools = %+v, want empty", cfg.CloudPools)
	}
	if cfg.SnapshotIDSet {
		t.Error("SnapshotIDSet should be false when snapshot_id is unset")
	}
}

// TestResolvePoolsDefaults is the test a hand-rolled parser fails: it proves
// optional() defaults declared inside a map(object({...})) TYPE expression
// -- not in `default` -- are actually applied. count omitted must resolve to
// 1, vpc_only omitted must resolve to true, and an explicit count = 0 must
// stay 0 rather than being treated as "omitted".
func TestResolvePoolsDefaults(t *testing.T) {
	decls := mustParseVariables(t, realModuleVariables)
	tfvars := mustParseTFVars(t, "testdata/pools.tfvars")

	cfg, diags := Resolve(decls, tfvars, nil)
	if HasErrors(diags) {
		t.Fatalf("unexpected errors: %v", diags)
	}

	wantBareMetal := map[string]BareMetalPool{
		"gpu":  {Name: "gpu", Plan: "vbm-6c-32gb-amd", Count: 2},
		"solo": {Name: "solo", Plan: "vbm-6c-32gb-amd", Count: 1}, // count omitted -> 1
		"off":  {Name: "off", Plan: "vbm-6c-32gb-amd", Count: 0},  // explicit 0 stays 0
	}
	if len(cfg.BareMetalPools) != len(wantBareMetal) {
		t.Fatalf("BareMetalPools = %+v, want %d entries", cfg.BareMetalPools, len(wantBareMetal))
	}
	for _, got := range cfg.BareMetalPools {
		want, ok := wantBareMetal[got.Name]
		if !ok {
			t.Errorf("unexpected pool %q", got.Name)
			continue
		}
		if got != want {
			t.Errorf("pool %q = %+v, want %+v", got.Name, got, want)
		}
	}
	// locals.tf sorts pool keys: assert this package does too.
	wantOrder := []string{"gpu", "off", "solo"}
	for i, name := range wantOrder {
		if cfg.BareMetalPools[i].Name != name {
			t.Errorf("BareMetalPools[%d].Name = %q, want %q (expected sorted order %v)", i, cfg.BareMetalPools[i].Name, name, wantOrder)
		}
	}

	wantCloud := map[string]CloudPool{
		"cgpu": {Name: "cgpu", Plan: "voc-c-4c-8gb-150s-amd", Count: 1, VPCOnly: false},
		"bare": {Name: "bare", Plan: "voc-c-4c-8gb-150s-amd", Count: 1, VPCOnly: true}, // count and vpc_only both omitted
	}
	if len(cfg.CloudPools) != len(wantCloud) {
		t.Fatalf("CloudPools = %+v, want %d entries", cfg.CloudPools, len(wantCloud))
	}
	for _, got := range cfg.CloudPools {
		want, ok := wantCloud[got.Name]
		if !ok {
			t.Errorf("unexpected pool %q", got.Name)
			continue
		}
		if got != want {
			t.Errorf("pool %q = %+v, want %+v", got.Name, got, want)
		}
	}
}

// TestResolveRegionMissing asserts that a tfvars with no region, and no
// --region override, is a fatal (error-severity) diagnostic naming the flag.
func TestResolveRegionMissing(t *testing.T) {
	decls := mustParseVariables(t, realModuleVariables)
	_, diags := Resolve(decls, map[string]TFVarValue{}, nil)
	if !HasErrors(diags) {
		t.Fatal("expected an error diagnostic when region is unset")
	}
	found := false
	for _, d := range diags {
		if d.Severity == SeverityError && containsRegionHint(d.Summary) {
			found = true
		}
	}
	if !found {
		t.Errorf("expected an error mentioning --region, got: %v", diags)
	}
}

func containsRegionHint(s string) bool {
	return len(s) > 0 && (contains(s, "region") && contains(s, "--region"))
}

func contains(s, substr string) bool {
	for i := 0; i+len(substr) <= len(s); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

// TestResolveRegionOverride asserts --region wins even when the tfvars sets
// no region at all.
func TestResolveRegionOverride(t *testing.T) {
	decls := mustParseVariables(t, realModuleVariables)
	cfg, diags := Resolve(decls, map[string]TFVarValue{}, map[string]string{"region": "sao"})
	if HasErrors(diags) {
		t.Fatalf("unexpected errors: %v", diags)
	}
	if cfg.Region != "sao" {
		t.Errorf("Region = %q, want %q", cfg.Region, "sao")
	}
}

// TestResolveUndeclaredTFVarsWarns asserts an unknown tfvars key produces a
// warning naming it, not an error.
func TestResolveUndeclaredTFVarsWarns(t *testing.T) {
	decls := mustParseVariables(t, realModuleVariables)
	tfvars := mustParseTFVars(t, "testdata/minimal.tfvars")
	tfvars["totally_made_up_variable"] = tfvars["region"] // reuse a valid range/value, only the name matters

	_, diags := Resolve(decls, tfvars, nil)
	if HasErrors(diags) {
		t.Fatalf("unexpected errors: %v", diags)
	}
	found := false
	for _, d := range diags {
		if d.Severity == SeverityWarning && contains(d.Summary, "totally_made_up_variable") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a warning naming the undeclared variable, got: %v", diags)
	}
}

// TestFallbackDefaultsMatchModule locks resolve.go's fallbackDefaults to the
// real variables.tf. Those literals are only reached on the degraded path
// where variables.tf could not be read, which means a stale one would never
// show up in ordinary use -- it would silently price the wrong plan for
// whoever hit that path. This is the test that makes the duplication safe.
func TestFallbackDefaultsMatchModule(t *testing.T) {
	decls, diags := ParseVariables(realModuleVariables)
	if diags.HasErrors() {
		t.Fatalf("unexpected diagnostics parsing %s: %s", realModuleVariables, diags.Error())
	}

	cfg, resolveDiags := Resolve(decls, map[string]TFVarValue{}, map[string]string{"region": "ams"})
	for _, d := range resolveDiags {
		if d.Severity == SeverityError {
			t.Fatalf("resolving module defaults: %s", d.Format())
		}
	}

	if cfg.ClusterName != fallbackDefaults.ClusterName {
		t.Errorf("cluster_name: module default %q, fallback %q", cfg.ClusterName, fallbackDefaults.ClusterName)
	}
	if cfg.DeployNodes != fallbackDefaults.DeployNodes {
		t.Errorf("deploy_nodes: module default %v, fallback %v", cfg.DeployNodes, fallbackDefaults.DeployNodes)
	}
	if cfg.ControlPlaneCount != fallbackDefaults.ControlPlaneCount {
		t.Errorf("control_plane_count: module default %d, fallback %d", cfg.ControlPlaneCount, fallbackDefaults.ControlPlaneCount)
	}
	if cfg.ControlPlanePlan != fallbackDefaults.ControlPlanePlan {
		t.Errorf("control_plane_plan: module default %q, fallback %q", cfg.ControlPlanePlan, fallbackDefaults.ControlPlanePlan)
	}
	if cfg.JumphostPlan != fallbackDefaults.JumphostPlan {
		t.Errorf("jumphost_plan: module default %q, fallback %q", cfg.JumphostPlan, fallbackDefaults.JumphostPlan)
	}
	if cfg.LBNodes != fallbackDefaults.LBNodes {
		t.Errorf("lb_nodes: module default %d, fallback %d", cfg.LBNodes, fallbackDefaults.LBNodes)
	}
	if cfg.IngressController != fallbackDefaults.IngressController {
		t.Errorf("ingress_controller: module default %q, fallback %q", cfg.IngressController, fallbackDefaults.IngressController)
	}

	wantGB, err := parseDiskSizeGB(fallbackDefaults.ImageDiskSize)
	if err != nil {
		t.Fatalf("fallback image_disk_size %q is not parseable: %v", fallbackDefaults.ImageDiskSize, err)
	}
	if cfg.ImageDiskGB != wantGB {
		t.Errorf("image_disk_size: module default resolves to %g GB, fallback %q is %g GB", cfg.ImageDiskGB, fallbackDefaults.ImageDiskSize, wantGB)
	}
}

// TestPoolDefaultsMatchModule locks the degraded-path pool attribute defaults
// to the optional() markers in the real variables.tf. Same rationale as
// TestFallbackDefaultsMatchModule: the constants are only reached when
// variables.tf is unreadable, so drift there would never surface in normal
// use.
func TestPoolDefaultsMatchModule(t *testing.T) {
	decls, diags := ParseVariables(realModuleVariables)
	if diags.HasErrors() {
		t.Fatalf("unexpected diagnostics parsing %s: %s", realModuleVariables, diags.Error())
	}

	// A pool literal that omits every optional attribute. Resolved WITH the
	// declaration, typeexpr fills them; the constants must agree.
	tfvars := map[string]TFVarValue{
		"gpu_bare_metal_pools": {Value: cty.ObjectVal(map[string]cty.Value{
			"bm": cty.ObjectVal(map[string]cty.Value{"plan": cty.StringVal("vbm-6c-32gb-amd")}),
		})},
		"gpu_cloud_pools": {Value: cty.ObjectVal(map[string]cty.Value{
			"cl": cty.ObjectVal(map[string]cty.Value{"plan": cty.StringVal("voc-c-4c-8gb-150s-amd")}),
		})},
	}

	cfg, resolveDiags := Resolve(decls, tfvars, map[string]string{"region": "ams"})
	for _, d := range resolveDiags {
		if d.Severity == SeverityError {
			t.Fatalf("resolving pools against the module: %s", d.Format())
		}
	}

	if len(cfg.BareMetalPools) != 1 || len(cfg.CloudPools) != 1 {
		t.Fatalf("expected one pool of each kind, got %d bare metal and %d cloud", len(cfg.BareMetalPools), len(cfg.CloudPools))
	}
	if got := cfg.BareMetalPools[0].Count; got != defaultPoolCount {
		t.Errorf("gpu_bare_metal_pools count: module optional() default %d, constant %d", got, defaultPoolCount)
	}
	if got := cfg.CloudPools[0].Count; got != defaultPoolCount {
		t.Errorf("gpu_cloud_pools count: module optional() default %d, constant %d", got, defaultPoolCount)
	}
	if got := cfg.CloudPools[0].VPCOnly; got != defaultPoolVPCOnly {
		t.Errorf("gpu_cloud_pools vpc_only: module optional() default %v, constant %v", got, defaultPoolVPCOnly)
	}
}

// TestDecodePoolsWithoutDeclarations covers the degraded path directly: no
// variables.tf at all, so no type constraint carried the optional() defaults,
// and the decoders must supply them rather than rejecting the pool.
func TestDecodePoolsWithoutDeclarations(t *testing.T) {
	tfvars := map[string]TFVarValue{
		"region": {Value: cty.StringVal("ams")},
		"gpu_cloud_pools": {Value: cty.ObjectVal(map[string]cty.Value{
			"a100": cty.ObjectVal(map[string]cty.Value{"plan": cty.StringVal("vcg-a100-12c-120g-80vram")}),
		})},
	}

	cfg, diags := Resolve(nil, tfvars, nil)
	for _, d := range diags {
		if d.Severity == SeverityError {
			t.Fatalf("degraded path should not error: %s", d.Format())
		}
	}
	if len(cfg.CloudPools) != 1 {
		t.Fatalf("expected one cloud pool, got %d", len(cfg.CloudPools))
	}
	if cfg.CloudPools[0].Count != defaultPoolCount || !cfg.CloudPools[0].VPCOnly {
		t.Errorf("degraded-path defaults: count = %d, vpc_only = %v; want %d and true",
			cfg.CloudPools[0].Count, cfg.CloudPools[0].VPCOnly, defaultPoolCount)
	}
}
