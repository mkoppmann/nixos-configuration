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
  };

  # Disables kexec and hibernation, which could replace the running kernel.
  security.protectKernelImage = true;
}
