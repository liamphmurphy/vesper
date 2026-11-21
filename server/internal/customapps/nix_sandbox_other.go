//go:build !darwin

package customapps

func nixSandboxCommand(_ string, _ []string, cmdPath string, args []string) (string, []string, error) {
	return cmdPath, args, nil
}
