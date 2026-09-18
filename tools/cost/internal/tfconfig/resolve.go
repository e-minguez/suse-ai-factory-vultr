package tfconfig

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/ext/typeexpr"
	"github.com/zclconf/go-cty/cty"
	"github.com/zclconf/go-cty/cty/convert"
	"github.com/zclconf/go-cty/cty/gocty"
)

// Config is the ONLY thing Resolve hands back to the rest of this program.
// It is the security boundary promised by the design: every field is a
// narrow, already-typed Go value copied out of cty during resolution, and
// nothing else -- no cty.Value, no map of "everything else the tfvars set" --
// survives past this package. A new sensitive variable added to variables.tf
// later is safe by construction: Resolve would have to be edited by hand to
// start reading it, unlike a deny-list, which is safe only until someone
// forgets to update it.
//
// SnapshotIDSet records presence only. The snapshot ID itself is never a
// pricing input (variables.tf:636's snapshot_id only tells Terraform to
// reuse an existing snapshot instead of building one; either way there is
// exactly one snapshot to price -- see pricing.Expand) and is never copied
// here.
type Config struct {
	Region            string
	ClusterName       string
	DeployNodes       bool
	ControlPlaneCount int
	ControlPlanePlan  string
	JumphostPlan      string
	BareMetalPools    []BareMetalPool
	CloudPools        []CloudPool
	LBNodes           int
	IngressController string
	ImageDiskGB       float64
	SnapshotIDSet     bool
}

// BareMetalPool mirrors one entry of gpu_bare_metal_pools after optional()
// defaults have been applied (variables.tf:274-309).
type BareMetalPool struct {
	Name  string
	Plan  string
	Count int
}

// CloudPool mirrors one entry of gpu_cloud_pools after optional() defaults
// have been applied (variables.tf:311-377). plan_type is deliberately not
// carried into Config: it steers Terraform's own availability pre-check
// (availability.tf) and has no effect on price.
type CloudPool struct {
	Name    string
	Plan    string
	Count   int
	VPCOnly bool
}

// fallbackDefaults duplicates modules/ai-factory-ha/variables.tf's own
// `default` values, used ONLY on the degraded path where variables.tf could
// not be read at all (see Resolve). Duplicated defaults are exactly the drift
// the --defaults design exists to avoid, so TestFallbackDefaultsMatchModule
// parses the real variables.tf and fails if any of these has gone stale.
// Keys are variable names; values are the literal defaults.
var fallbackDefaults = struct {
	ClusterName       string
	DeployNodes       bool
	ControlPlaneCount int
	ControlPlanePlan  string
	JumphostPlan      string
	LBNodes           int
	IngressController string
	ImageDiskSize     string
}{
	ClusterName:       "suse-ai-factory",
	DeployNodes:       true,
	ControlPlaneCount: 3,
	ControlPlanePlan:  "vx1-g-4c-16g-240s",
	JumphostPlan:      "vc2-6c-16gb",
	LBNodes:           1,
	IngressController: "traefik",
	ImageDiskSize:     "8G",
}

// diskSizePattern mirrors variables.tf:625's own validation regex for
// image_disk_size, so a malformed size is rejected the same way here as it
// would be by `terraform plan`.
var diskSizePattern = regexp.MustCompile(`^([1-9][0-9]*)([KMGT])$`)

// Resolve combines a module's variable declarations with a tfvars file's
// values into a Config, following variables.tf:1-706's shape (see the field
// list on Config). overrides lets a CLI flag win over both the tfvars and
// the module default for a variable -- today only used for --region, since
// region has no default at all (variables.tf:1) and is otherwise the single
// most common reason a tfvars can't be priced.
//
// decls may be nil or incomplete (see the "variables.tf unreadable" row in
// the plan's error-handling table): a variable with no VariableDecl simply
// has no known type and no known default, so it resolves only if the tfvars
// (or an override) sets it, and is reported as an error otherwise.
func Resolve(decls map[string]*VariableDecl, tfvars map[string]TFVarValue, overrides map[string]string) (Config, []Diagnostic) {
	var diags []Diagnostic
	var cfg Config

	// tfvars key not declared: warn, name only. Skipped entirely when decls
	// is empty, since that means variables.tf itself could not be read and
	// there is nothing to check membership against.
	if len(decls) > 0 {
		for name, tv := range tfvars {
			if _, ok := decls[name]; !ok {
				r := tv.Range
				diags = append(diags, Diagnostic{
					Severity: SeverityWarning,
					Summary:  fmt.Sprintf("tfvars sets %q, which is not declared in variables.tf", name),
					Subject:  &r,
				})
			}
		}
	}

	resolve := func(name string) (cty.Value, bool, []Diagnostic) {
		return resolveValue(decls, tfvars, overrides, name)
	}

	// region: variables.tf:1 declares it with NO default. Absent -> fatal,
	// and the message says so plainly rather than reporting a generic
	// "could not resolve" for the one variable where that is always the
	// actual problem.
	if v, ok, d := resolve("region"); ok {
		diags = append(diags, d...)
		cfg.Region = v.AsString()
	} else {
		diags = append(diags, d...)
		diags = append(diags, Diagnostic{
			Severity: SeverityError,
			Summary:  "variable \"region\" has no default and no value was found in the tfvars; pass --region",
		})
	}

	stringVar := func(name, fallback string) string {
		v, ok, d := resolve(name)
		diags = append(diags, d...)
		if !ok {
			if len(decls) == 0 {
				// variables.tf unreadable: fall back to the module's known
				// shipped default so a tfvars that only sets the handful of
				// values it wants to override still prices sanely, rather
				// than every unset variable becoming individually fatal.
				return fallback
			}
			diags = append(diags, Diagnostic{Severity: SeverityError, Summary: fmt.Sprintf("variable %q could not be resolved: no value in the tfvars and no default in variables.tf", name)})
			return fallback
		}
		return v.AsString()
	}

	boolVar := func(name string, fallback bool) bool {
		v, ok, d := resolve(name)
		diags = append(diags, d...)
		if !ok {
			if len(decls) == 0 {
				return fallback
			}
			diags = append(diags, Diagnostic{Severity: SeverityError, Summary: fmt.Sprintf("variable %q could not be resolved: no value in the tfvars and no default in variables.tf", name)})
			return fallback
		}
		var b bool
		if err := gocty.FromCtyValue(v, &b); err != nil {
			diags = append(diags, Diagnostic{Severity: SeverityError, Summary: fmt.Sprintf("variable %q: expected bool", name)})
			return fallback
		}
		return b
	}

	intVar := func(name string, fallback int) int {
		v, ok, d := resolve(name)
		diags = append(diags, d...)
		if !ok {
			if len(decls) == 0 {
				return fallback
			}
			diags = append(diags, Diagnostic{Severity: SeverityError, Summary: fmt.Sprintf("variable %q could not be resolved: no value in the tfvars and no default in variables.tf", name)})
			return fallback
		}
		var n int
		if err := gocty.FromCtyValue(v, &n); err != nil {
			diags = append(diags, Diagnostic{Severity: SeverityError, Summary: fmt.Sprintf("variable %q: expected a whole number", name)})
			return fallback
		}
		return n
	}

	cfg.ClusterName = stringVar("cluster_name", fallbackDefaults.ClusterName)
	cfg.DeployNodes = boolVar("deploy_nodes", fallbackDefaults.DeployNodes)
	cfg.ControlPlaneCount = intVar("control_plane_count", fallbackDefaults.ControlPlaneCount)
	cfg.ControlPlanePlan = stringVar("control_plane_plan", fallbackDefaults.ControlPlanePlan)
	cfg.JumphostPlan = stringVar("jumphost_plan", fallbackDefaults.JumphostPlan)
	cfg.LBNodes = intVar("lb_nodes", fallbackDefaults.LBNodes)
	cfg.IngressController = stringVar("ingress_controller", fallbackDefaults.IngressController)

	imageDiskSize := stringVar("image_disk_size", fallbackDefaults.ImageDiskSize)
	gb, err := parseDiskSizeGB(imageDiskSize)
	if err != nil {
		diags = append(diags, Diagnostic{Severity: SeverityError, Summary: "image_disk_size must match <positive integer><K|M|G|T>"})
		gb = 8
	}
	cfg.ImageDiskGB = gb

	if v, ok, d := resolve("snapshot_id"); ok {
		diags = append(diags, d...)
		cfg.SnapshotIDSet = !v.IsNull()
	} else {
		diags = append(diags, d...)
		cfg.SnapshotIDSet = false
	}

	if v, ok, d := resolve("gpu_bare_metal_pools"); ok {
		diags = append(diags, d...)
		pools, err := decodeBareMetalPools(v)
		if err != nil {
			diags = append(diags, Diagnostic{Severity: SeverityError, Summary: "gpu_bare_metal_pools: " + err.Error()})
		}
		cfg.BareMetalPools = pools
	} else {
		diags = append(diags, d...)
	}

	if v, ok, d := resolve("gpu_cloud_pools"); ok {
		diags = append(diags, d...)
		pools, err := decodeCloudPools(v)
		if err != nil {
			diags = append(diags, Diagnostic{Severity: SeverityError, Summary: "gpu_cloud_pools: " + err.Error()})
		}
		cfg.CloudPools = pools
	} else {
		diags = append(diags, d...)
	}

	return cfg, diags
}

// resolveValue is the one place the spec's "convert first would lose the
// default" trap is avoided: for every value, whether it came from an
// override, the tfvars, or the variable's own `default`, optional() defaults
// (decl.Defaults.Apply) are applied BEFORE convert.Convert -- never after.
// Converting a value missing an optional attribute produces null for that
// attribute (cty.ObjectWithOptionalAttrs allows exactly that), which leaves
// Apply nothing to fill if it runs second. See resolve.go's package comment
// and the plan this package implements.
func resolveValue(decls map[string]*VariableDecl, tfvars map[string]TFVarValue, overrides map[string]string, name string) (cty.Value, bool, []Diagnostic) {
	decl := decls[name]

	applyAndConvert := func(v cty.Value, subject *hcl.Range) (cty.Value, []Diagnostic) {
		if decl == nil {
			return v, nil
		}
		if decl.Defaults != nil {
			v = decl.Defaults.Apply(v)
		}
		converted, err := convert.Convert(v, decl.Type)
		if err != nil {
			return cty.NilVal, []Diagnostic{{
				Severity: SeverityError,
				Summary:  fmt.Sprintf("variable %q: value does not match expected type %s", name, typeexpr.TypeString(decl.Type)),
				Subject:  subject,
			}}
		}
		return converted, nil
	}

	if ov, ok := overrides[name]; ok {
		v, diags := applyAndConvert(cty.StringVal(ov), nil)
		if diags != nil {
			return cty.NilVal, false, diags
		}
		return v, true, nil
	}

	if tv, ok := tfvars[name]; ok {
		r := tv.Range
		v, diags := applyAndConvert(tv.Value, &r)
		if diags != nil {
			return cty.NilVal, false, diags
		}
		return v, true, nil
	}

	if decl != nil && decl.HasDefault {
		v, diags := applyAndConvert(decl.Default, nil)
		if diags != nil {
			return cty.NilVal, false, diags
		}
		return v, true, nil
	}

	return cty.NilVal, false, nil
}

// poolElements returns v's elements keyed by pool name, in sorted order,
// regardless of whether v itself is cty.Map or cty.Object typed. The two are
// interchangeable here on purpose: when a VariableDecl is available, Resolve
// has already run convert.Convert(v, decl.Type) and v is a genuine Map; when
// it is not (variables.tf unreadable -- see Resolve's package comment), v is
// whatever HCL's object-constructor syntax `{ ... }` produced for the
// tfvars, which is always cty.Object. AsValueMap works on both, so decoding
// does not need to care which one it got.
func poolElements(v cty.Value) []string {
	m := v.AsValueMap()
	names := make([]string, 0, len(m))
	for name := range m {
		names = append(names, name)
	}
	sort.Strings(names) // matches locals.tf's sort(keys(...)) iteration order
	return names
}

// Pool attribute defaults, duplicated from the optional() markers in
// variables.tf:274-377. On the normal path these are never consulted:
// typeexpr.Defaults.Apply has already filled them in resolveValue. They exist
// for the degraded path where variables.tf could not be read, and so there is
// no type constraint to carry them -- without these, a perfectly valid
// `{ plan = "..." }` pool with count omitted would be a hard error. Locked to
// the module by TestPoolDefaultsMatchModule.
const (
	defaultPoolCount   = 1
	defaultPoolVPCOnly = true
)

// poolAttr reads one attribute off a pool object, reporting whether it was
// present at all. Absent is not an error here -- see the constants above.
func poolAttr(obj cty.Value, name string) (cty.Value, bool) {
	if !obj.Type().IsObjectType() && !obj.Type().IsMapType() {
		return cty.NilVal, false
	}
	if obj.Type().IsObjectType() && !obj.Type().HasAttribute(name) {
		return cty.NilVal, false
	}
	v := obj.GetAttr(name)
	if v.IsNull() {
		return cty.NilVal, false
	}
	return v, true
}

func poolString(obj cty.Value, name string) (string, error) {
	v, ok := poolAttr(obj, name)
	if !ok {
		return "", fmt.Errorf("missing required attribute %q", name)
	}
	var s string
	if err := gocty.FromCtyValue(v, &s); err != nil {
		return "", fmt.Errorf("attribute %q: expected a string", name)
	}
	return s, nil
}

func poolInt(obj cty.Value, name string, fallback int) (int, error) {
	v, ok := poolAttr(obj, name)
	if !ok {
		return fallback, nil
	}
	var n int
	if err := gocty.FromCtyValue(v, &n); err != nil {
		return 0, fmt.Errorf("attribute %q: expected a whole number", name)
	}
	return n, nil
}

func poolBool(obj cty.Value, name string, fallback bool) (bool, error) {
	v, ok := poolAttr(obj, name)
	if !ok {
		return fallback, nil
	}
	var b bool
	if err := gocty.FromCtyValue(v, &b); err != nil {
		return false, fmt.Errorf("attribute %q: expected a bool", name)
	}
	return b, nil
}

func decodeBareMetalPools(v cty.Value) ([]BareMetalPool, error) {
	if v.IsNull() {
		return nil, nil
	}
	m := v.AsValueMap()
	names := poolElements(v)
	pools := make([]BareMetalPool, 0, len(names))
	for _, name := range names {
		plan, err := poolString(m[name], "plan")
		if err != nil {
			return nil, fmt.Errorf("pool %q: %w", name, err)
		}
		count, err := poolInt(m[name], "count", defaultPoolCount)
		if err != nil {
			return nil, fmt.Errorf("pool %q: %w", name, err)
		}
		pools = append(pools, BareMetalPool{Name: name, Plan: plan, Count: count})
	}
	return pools, nil
}

func decodeCloudPools(v cty.Value) ([]CloudPool, error) {
	if v.IsNull() {
		return nil, nil
	}
	m := v.AsValueMap()
	names := poolElements(v)
	pools := make([]CloudPool, 0, len(names))
	for _, name := range names {
		plan, err := poolString(m[name], "plan")
		if err != nil {
			return nil, fmt.Errorf("pool %q: %w", name, err)
		}
		count, err := poolInt(m[name], "count", defaultPoolCount)
		if err != nil {
			return nil, fmt.Errorf("pool %q: %w", name, err)
		}
		vpcOnly, err := poolBool(m[name], "vpc_only", defaultPoolVPCOnly)
		if err != nil {
			return nil, fmt.Errorf("pool %q: %w", name, err)
		}
		pools = append(pools, CloudPool{Name: name, Plan: plan, Count: count, VPCOnly: vpcOnly})
	}
	return pools, nil
}

// parseDiskSizeGB converts variables.tf:616's image_disk_size (e.g. "8G",
// "35G") to decimal gigabytes, matching variables.tf:625's own validation
// regex. K/M/G/T are read as decimal (1000-based) scale factors, consistent
// with how Vultr itself quotes plan disk sizes.
func parseDiskSizeGB(s string) (float64, error) {
	m := diskSizePattern.FindStringSubmatch(s)
	if m == nil {
		return 0, fmt.Errorf("invalid size")
	}
	n, err := strconv.ParseFloat(m[1], 64)
	if err != nil {
		return 0, err
	}
	switch m[2] {
	case "K":
		return n / 1e6, nil
	case "M":
		return n / 1e3, nil
	case "G":
		return n, nil
	case "T":
		return n * 1e3, nil
	}
	return 0, fmt.Errorf("invalid size")
}
