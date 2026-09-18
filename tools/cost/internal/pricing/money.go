// Package pricing turns a resolved tfconfig.Config into a priced report:
// expanding it into the module's actual resource inventory (resource.go),
// looking each one up in a vultr.Catalog, and billing it correctly for
// however many hours the caller asked about (price.go).
package pricing

import (
	"encoding/json"
	"fmt"
	"math/big"
)

// Micros is a US-dollar amount as millionths of a dollar (1_000_000 Micros =
// $1), stored as int64. Every money value in this tool passes through
// ParseMicros -- json.Number -> big.Rat -> Micros -- rather than float64, so
// e.g. Vultr's "0.153" becomes exactly 153000 and never a binary-float
// approximation that would make golden test files flap from one run, or one
// platform, to the next.
type Micros int64

// Dollars renders the amount as a float64 dollar figure. Used only by the
// renderers -- nothing in this package's own arithmetic uses it, to keep
// every intermediate result exact.
func (m Micros) Dollars() float64 {
	return float64(m) / 1_000_000
}

// ParseMicros converts a JSON number (decoded via json.Number, never
// float64) to whole millionths of a dollar.
func ParseMicros(n json.Number) (Micros, error) {
	s := n.String()
	if s == "" {
		s = "0"
	}
	r, ok := new(big.Rat).SetString(s)
	if !ok {
		return 0, fmt.Errorf("not a decimal number: %q", s)
	}
	r.Mul(r, big.NewRat(1_000_000, 1))
	r.Add(r, big.NewRat(1, 2)) // round half up; every input here is non-negative
	q := new(big.Int).Quo(r.Num(), r.Denom())
	return Micros(q.Int64()), nil
}
