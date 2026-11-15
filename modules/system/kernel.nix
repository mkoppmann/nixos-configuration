{ ... }:
{
  boot.kernel.sysctl = {
    # Hide kernel addresses and the kernel log from unprivileged users; both
    # help an attacker to defeat address randomisation.
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;

    # BPF runs code inside the kernel: only root may load programs, and
    # JIT-compiled code is hardened against JIT spraying.
    "kernel.unprivileged_bpf_disabled" = 1;
    "net.core.bpf_jit_harden" = 2;

    # A process may only debug its own descendants, so a compromised service
    # cannot read the memory of other processes running as the same user.
    "kernel.yama.ptrace_scope" = 1;

    # ICMP redirects let other hosts rewrite the routing table. The routes
    # here are static, so neither accept nor send them.
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.secure_redirects" = 0;
    "net.ipv4.conf.default.secure_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;

    # Source-routed packets dictate their own path, e.g. to bypass filtering.
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.default.accept_source_route" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.default.accept_source_route" = 0;

    # Operations submitted through io_uring bypass the services’ system call
    # filters, and it has been a frequent source of kernel exploits.
    "kernel.io_uring_disabled" = 2;

    # Only root may load line disciplines; opening a terminal could otherwise
    # load rarely used ones.
    "dev.tty.ldisc_autoload" = 0;
  };

  boot.kernelParams = [
    # 32-bit x86 programs and their separate system call entry are disabled.
    "ia32_emulation=0"
    # Objects of different types never share a slab cache, and free pages are
    # handed out in random order; both make heap corruption harder to exploit.
    "slab_nomerge"
    "page_alloc.shuffle=1"
    # Writes through /proc/PID/mem respect page protections unless the writer
    # traces the process, so they can’t bypass MemoryDenyWriteExecute.
    "proc_mem.force_override=ptrace"
    "debugfs=off"
  ];

  # Socket families nothing here uses: network protocols, and AF_ALG, which
  # hands the kernel’s crypto code to programs. Opening a socket of one of them
  # would otherwise load its module, even for unprivileged users.
  boot.blacklistedKernelModules = [
    "af_alg"
    "algif_aead"
    "algif_hash"
    "algif_rng"
    "algif_skcipher"
    "appletalk"
    "atm"
    "ax25"
    "bluetooth"
    "caif_socket"
    "can"
    "ieee802154_socket"
    "kcm"
    "llc2"
    "netrom"
    "nfc"
    "phonet"
    "qrtr"
    "rds"
    "rose"
    "rxrpc"
    "sctp"
    "smc"
    "tipc"
    "x25"
  ];

  # Disables kexec and hibernation, which could replace the running kernel.
  security.protectKernelImage = true;

  # A crash is logged with its metadata, but the memory of the process, which
  # can hold keys and user data, is not written to disk.
  systemd.coredump.settings.Coredump.Storage = "none";
}
