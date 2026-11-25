// Package calc is the smallest module that exercises go.yml's gates:
// _self_ci.yml runs the reusable workflow against it with the race detector,
// go vet, the tidy check, coverage and diff-coverage on.
package calc

// Add returns the sum of a and b.
func Add(a, b int) int {
	return a + b
}
