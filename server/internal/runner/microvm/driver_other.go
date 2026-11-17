//go:build !(darwin && arm64)

package microvm

import (
	"context"
	"errors"
)

type unsupportedDriver struct{}

// NewVZDriver returns an error on platforms without Apple Virtualization.framework.
func NewVZDriver() Driver { return unsupportedDriver{} }

func (unsupportedDriver) Start(context.Context, VMConfig) (VM, error) {
	return nil, errors.New("microvm: Apple Virtualization.framework requires darwin/arm64")
}
