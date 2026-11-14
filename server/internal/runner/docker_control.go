package runner

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"strings"
)

// Docker resolves a bare alias on any network a container joins. Resolve the
// control API on the primary network before attaching test/playground networks,
// then pin it in /etc/hosts. Repeating this each launch picks up API restarts.
func (d *Docker) controlAPIHost(ctx context.Context, rawURL string) (string, error) {
	if rawURL == "" || d.Network == "" || d.Network == "bridge" {
		return "", nil
	}
	u, err := url.Parse(rawURL)
	if err != nil || u.Hostname() == "" {
		return "", fmt.Errorf("runner: invalid control API URL")
	}
	host := u.Hostname()
	if net.ParseIP(host) != nil || host == "host.docker.internal" {
		return "", nil // Explicit addresses and the host-gateway mapping are already pinned.
	}
	var network struct {
		Name       string
		Containers map[string]struct{ Name, IPv4Address, IPv6Address string }
	}
	if _, err := d.do(ctx, "GET", "/networks/"+url.PathEscape(d.Network), nil, "", &network); err != nil {
		return "", fmt.Errorf("inspect control API network: %w", err)
	}
	address := ""
	for id, endpoint := range network.Containers {
		var container struct {
			NetworkSettings struct {
				Networks map[string]struct{ Aliases []string }
			}
		}
		if _, err := d.do(ctx, "GET", "/containers/"+url.PathEscape(id)+"/json", nil, "", &container); err != nil {
			if isStatus(err, 404) {
				continue // A different turn on the network just exited.
			}
			return "", fmt.Errorf("inspect control API endpoint: %w", err)
		}
		aliases := append([]string{endpoint.Name}, container.NetworkSettings.Networks[network.Name].Aliases...)
		for _, alias := range aliases {
			if !strings.EqualFold(strings.TrimSuffix(alias, "."), strings.TrimSuffix(host, ".")) {
				continue
			}
			ip, _, err := net.ParseCIDR(endpoint.IPv4Address)
			if err != nil {
				ip, _, err = net.ParseCIDR(endpoint.IPv6Address)
			}
			if err != nil || (address != "" && address != ip.String()) {
				return "", fmt.Errorf("runner: control API has no unique address on its primary network")
			}
			address = ip.String()
		}
	}
	if address == "" {
		return "", fmt.Errorf("runner: control API hostname was not found on its primary Docker network")
	}
	return host + ":" + address, nil
}
