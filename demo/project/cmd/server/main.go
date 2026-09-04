package main

import (
	"fmt"
	"net/http"
)

// helloHandler greets every visitor.
func helloHandler(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if name == "" {
		name = "world"
	}
	// TODO: add auth before this handler ships
	fmt.Fprintf(w, "hello, %s\n", name)
}

func main() {
	http.HandleFunc("/hello", helloHandler)
	http.HandleFunc("/", helloHandler)
	fmt.Println("hello from server on :8080")
}
