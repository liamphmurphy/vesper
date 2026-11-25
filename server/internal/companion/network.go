package companion

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"slices"
	"strings"
	"time"
)

// NetworkInfo describes how a paired companion device can reach this Mac over
// the local network and Tailscale.
type NetworkInfo struct {
	HostName           string   `json:"host_name"`
	LANAddresses       []string `json:"lan_addresses"`
	TailscaleAddresses []string `json:"tailscale_addresses"`
	TailscaleDNS       string   `json:"tailscale_dns,omitempty"`
}

// DiscoverNetwork inspects local network interfaces and (best-effort) Tailscale
// status to find reachable LAN and Tailscale endpoints for this host.
func DiscoverNetwork(ctx context.Context) NetworkInfo {
	host, _ := os.Hostname()
	host = strings.TrimSuffix(strings.TrimSpace(host), ".local")
	if host == "" {
		host = "Mac"
	}

	info := NetworkInfo{
		HostName:           host,
		LANAddresses:       []string{},
		TailscaleAddresses: []string{},
	}

	ifaces, err := net.Interfaces()
	if err == nil {
		for _, iface := range ifaces {
			if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
				continue
			}
			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}
			for _, addr := range addrs {
				ip := ipFromAddr(addr)
				if ip == nil {
					continue
				}
				ip4 := ip.To4()
				if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
					continue
				}
				switch {
				case isTailscaleIPv4(ip4):
					info.TailscaleAddresses = appendUnique(info.TailscaleAddresses, ip4.String())
				case isPrivateLANIPv4(ip4):
					info.LANAddresses = appendUnique(info.LANAddresses, ip4.String())
				}
			}
		}
	}

	slices.Sort(info.LANAddresses)
	slices.Sort(info.TailscaleAddresses)

	if dns := discoverTailscaleDNS(ctx); dns != "" {
		info.TailscaleDNS = dns
	}
	return info
}

func ipFromAddr(addr net.Addr) net.IP {
	switch v := addr.(type) {
	case *net.IPNet:
		return v.IP
	case *net.IPAddr:
		return v.IP
	default:
		return nil
	}
}

// isTailscaleIPv4 reports whether ip is in Tailscale's CGNAT range (100.64.0.0/10).
func isTailscaleIPv4(ip net.IP) bool {
	return len(ip) == 4 && ip[0] == 100 && ip[1] >= 64 && ip[1] <= 127
}

// isPrivateLANIPv4 reports whether ip is an RFC 1918 private IPv4 address.
func isPrivateLANIPv4(ip net.IP) bool {
	if len(ip) != 4 {
		return false
	}
	switch {
	case ip[0] == 10:
		return true
	case ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31:
		return true
	case ip[0] == 192 && ip[1] == 168:
		return true
	default:
		return false
	}
}

func appendUnique(dst []string, v string) []string {
	if slices.Contains(dst, v) {
		return dst
	}
	return append(dst, v)
}

func discoverTailscaleDNS(ctx context.Context) string {
	bin, err := exec.LookPath("tailscale")
	if err != nil {
		// On macOS with the App Store / standalone Tailscale app, the CLI often
		// lives inside Tailscale.app when not symlinked onto PATH.
		const macAppCLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
		if st, serr := os.Stat(macAppCLI); serr == nil && !st.IsDir() {
			bin = macAppCLI
		} else {
			return ""
		}
	}
	tctx, cancel := context.WithTimeout(ctx, 800*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(tctx, bin, "status", "--json").Output()
	if err != nil {
		return ""
	}
	var status struct {
		Self struct {
			DNSName string `json:"DNSName"`
		} `json:"Self"`
	}
	if err := json.Unmarshal(out, &status); err != nil {
		return ""
	}
	return strings.TrimSuffix(strings.TrimSpace(status.Self.DNSName), ".")
}
