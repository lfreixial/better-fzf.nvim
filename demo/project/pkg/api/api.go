package api

import "errors"

// ErrGreeting indicates the greeter failed.
var ErrGreeting = errors.New("greeter: handler failed")

// Handler processes one greeting request.
type Handler struct{}

// Run executes the handler pipeline. TODO: add tracing.
func (h *Handler) Run() error {
	return ErrGreeting
}
