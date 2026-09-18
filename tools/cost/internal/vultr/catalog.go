package vultr

// Catalog resolves a plan ID to its pricing data. Implementations: a live
// HTTP fetch, a file loaded from --plans, a warm on-disk cache, and
// MapCatalog itself, used directly by tests and as the common concrete type
// everything else decodes into.
type Catalog interface {
	// Lookup returns the plan and whether it was found. It never errors: an
	// unknown plan ID is the caller's problem to report with context (which
	// resource, what quantity, whether --allow-unknown-plans was set), not
	// this interface's.
	Lookup(id string) (Plan, bool)
}

// MapCatalog is a Catalog backed by a plain map, keyed by plan ID.
type MapCatalog map[string]Plan

// Lookup implements Catalog.
func (c MapCatalog) Lookup(id string) (Plan, bool) {
	p, ok := c[id]
	return p, ok
}

// Merge returns a new MapCatalog containing every plan from c and other,
// with other's entries winning on a colliding ID.
func (c MapCatalog) Merge(other MapCatalog) MapCatalog {
	out := make(MapCatalog, len(c)+len(other))
	for id, p := range c {
		out[id] = p
	}
	for id, p := range other {
		out[id] = p
	}
	return out
}
