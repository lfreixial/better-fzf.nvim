package greeter

import "testing"

func TestGreet(t *testing.T) {
	if got := Greet("world"); got != "hello, world" {
		t.Fatalf("Greet() = %q, want %q", got, "hello, world")
	}
}
