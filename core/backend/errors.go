package backend

import "errors"

// Failure carries a stable UI cause without requiring clients to translate or
// parse diagnostic text. Details contain only explicitly supplied safe values.
type Failure struct {
	Code    string
	Details map[string]any
	Cause   error
}

func (e *Failure) Error() string { return e.Cause.Error() }
func (e *Failure) Unwrap() error { return e.Cause }

func WithFailure(err error, code string, details map[string]any) error {
	if err == nil {
		return nil
	}
	return &Failure{Code: code, Details: details, Cause: err}
}

func FailureDetails(err error) map[string]any {
	var failure *Failure
	if errors.As(err, &failure) {
		return failure.Details
	}
	return nil
}
