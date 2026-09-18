package tfconfig

import (
	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclparse"
	"github.com/zclconf/go-cty/cty"
)

// TFVarValue pairs a resolved value with the source range it came from, so a
// later diagnostic can cite "file:line:col" without ever printing the value
// itself.
type TFVarValue struct {
	Value cty.Value
	Range hcl.Range
}

// ParseTFVars reads a .tfvars file and evaluates each top-level attribute
// against an EMPTY *hcl.EvalContext -- no variables, no functions. A tfvars
// file is data, not code: nothing in it should be able to call a function or
// reference another value, and evaluating with an empty context turns any
// attempt into a parse diagnostic instead of a silent surprise.
func ParseTFVars(path string) (map[string]TFVarValue, hcl.Diagnostics) {
	parser := hclparse.NewParser()
	f, diags := parser.ParseHCLFile(path)
	if diags.HasErrors() {
		return nil, diags
	}

	attrs, attrDiags := f.Body.JustAttributes()
	diags = append(diags, attrDiags...)
	if attrDiags.HasErrors() {
		return nil, diags
	}

	values := make(map[string]TFVarValue, len(attrs))
	for name, attr := range attrs {
		val, valDiags := attr.Expr.Value(&hcl.EvalContext{})
		diags = append(diags, valDiags...)
		values[name] = TFVarValue{Value: val, Range: attr.Range}
	}
	return values, diags
}
