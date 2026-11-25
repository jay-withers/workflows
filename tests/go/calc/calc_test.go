package calc

import "testing"

func TestAdd(t *testing.T) {
	cases := []struct{ a, b, want int }{
		{1, 2, 3},
		{-1, 1, 0},
	}
	for _, c := range cases {
		if got := Add(c.a, c.b); got != c.want {
			t.Errorf("Add(%d, %d) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}
