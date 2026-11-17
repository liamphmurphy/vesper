// Command vesper-guest-agent runs inside Vesper microVMs as /sbin/init (PID 1)
// and serves host-to-guest RPC, process execution, and network/cache setup
// over AF_VSOCK.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

const agentVersion = "vesper-guest-agent/0.1"

func main() {
	if runtime.GOOS == "linux" && os.Getpid() == 1 {
		if err := bootstrapPID1(); err != nil {
			fmt.Fprintf(os.Stderr, "vesper-guest-agent: pid1 bootstrap failed: %v\n", err)
			// Keep PID 1 alive long enough for serial console output to flush before halt/reboot.
			time.Sleep(2 * time.Second)
			os.Exit(1)
		}
	}

	var listenUnix string
	flag.StringVar(&listenUnix, "listen-unix", "", "optional Unix socket path instead of AF_VSOCK (for host testing)")
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	srv := newAgentServer(log)
	defer srv.close()

	if runtime.GOOS == "linux" && os.Getpid() == 1 {
		startOrphanReaper(ctx, srv.execs)
		if err := setupGuestNetworking(log, srv.dnsStub); err != nil {
			log.Warn("guest networking setup incomplete", "err", err)
		}
	}

	var ln net.Listener
	var err error
	if listenUnix != "" {
		ln, err = net.Listen("unix", listenUnix)
	} else {
		ln, err = listenVSock(guestproto.PortRPC)
	}
	if err != nil {
		log.Error("listen rpc failed", "err", err)
		os.Exit(1)
	}
	defer ln.Close()

	if listenUnix == "" && runtime.GOOS == "linux" {
		// Notify host (CID 2) on PortReady that PortRPC is listening.
		go notifyHostReady(log)
	}

	log.Info("vesper-guest-agent ready", "version", agentVersion, "pid", os.Getpid())
	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()
	srv.serve(ctx, ln)
	if srv.shutdownRequested() && runtime.GOOS == "linux" && os.Getpid() == 1 {
		powerOffGuest()
	}
}
