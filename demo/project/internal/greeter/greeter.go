package greeter

import "fmt"

// Greet returns a friendly greeting. TODO: localise the greeting string.
func Greet(name string) string {
	return fmt.Sprintf("hello, %s", name)
}

// greeting is the private default greeting.
const greeting = "hello"

// handler wires the greeting for the API layer.
func handler() string { return Greet("handler") }
