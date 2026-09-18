# tools/cost is a self-contained Go module (its own go.mod) so the repo root
# stays Go-free. Run everything below from this directory.

.PHONY: build test fixtures vet clean

build:
	go build -o cost .

# Network-free: internal/vultr's fixtures under testdata/ are trimmed,
# committed snapshots of the live API, and the "live" staleness check below
# is deliberately excluded from the default build tag set.
test: vet
	go test ./...

vet:
	go vet ./...

# Refreshes internal/vultr/testdata's plan fixtures from the live,
# unauthenticated Vultr API, and runs the //go:build live staleness test
# against it. A public rate card rots silently, so this exists, but it makes
# a real network call and is therefore never part of `make test` or a plain
# `go test ./...`.
fixtures:
	go test ./internal/vultr/... -tags live -run TestLiveCatalogStillHasFixturePlans -v

clean:
	rm -f cost
