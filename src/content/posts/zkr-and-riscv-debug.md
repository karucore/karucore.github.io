---
author: Markku-Juhani O. Saarinen
pubDatetime: 2026-11-18T12:00:00.000Z
title: "Zkr (Hardware Random) and RISC-V Debug 1.0"
featured: true
draft: false
tags:
  - riscv
  - karu64
  - karudeb
  - zkr
  - entropy
  - debug
  - fpga
  - linux
description: "Karu64 now has the Zkr entropy source extension with a ring-oscillator noise source, a RISC-V Debug 1.0 debug module, and a debug authentication mechanism. All three run on the VCU118 FPGA with Linux 7.4-rc3."
---

>[!NOTE]
>**TL;DR:** Karu64 gains three opt-in features: the standard **Zkr** entropy source (`seed` CSR) backed by sampled ring oscillators, a **RISC-V Debug 1.0** debug module reachable through the FPGA's own JTAG port, and **debug authentication**. On 2026-11-18 the combined image passed its first board session on the VCU118, booting KaruDeb's Linux 7.4-rc3 kernel, which picks up Zkr on its own.

## Table of contents

## Zkr: the Entropy Source Extension

Zkr is the entropy source part of the ratified RISC-V Scalar Cryptography extensions. It defines one CSR, `seed` (`0x015`). Each read returns a status, `OPST`, in bits 31:30, and in state `ES16` also 16 bits of entropy. The other states are `BIST` (start-up test running), `WAIT` (no entropy available yet) and `DEAD` (failed). Accessing `seed` requires a CSR instruction that performs a write, normally `csrrw`. A successful poll consumes the returned word. M-mode always has access. S-mode and U-mode get access only if M-mode sets `mseccfg.SSEED` or `USEED`.

Zkr is deliberately an _entropy source_, not a random-number generator: its output is meant to seed a software DRBG, such as the Linux random pool.

### A ring-oscillator noise source

On the FPGA, Karu64's noise source is four free-running inverter rings of 3, 5, 7 and 9 stages, each sampled by a flip-flop on the 75 MHz system clock. Every inverter is placed by hand, and each ring has its own slices. One sample of the four rings is a raw 4-bit symbol, taken every 256 clocks.

<figure>
  <img
    src="/zkr-entropy-light.svg"
    class="no-frame dark:hidden"
    alt="One lane: an enable NAND gate and an odd chain of inverters in a loop, sampled by two flip-flops. Four lanes form a 4-bit raw symbol every 256 clocks, which passes decimation by k, per-lane health tests, packing into 16-bit words and a FIFO to the seed CSR. The mnoise GetNoise interface taps the raw symbols after decimation; mentropycfg sets k, the test cutoffs and a lock."
  />
  <img
    src="/zkr-entropy-dark.svg"
    class="no-frame hidden dark:block"
    alt="One lane: an enable NAND gate and an odd chain of inverters in a loop, sampled by two flip-flops. Four lanes form a 4-bit raw symbol every 256 clocks, which passes decimation by k, per-lane health tests, packing into 16-bit words and a FIFO to the seed CSR. The mnoise GetNoise interface taps the raw symbols after decimation; mentropycfg sets k, the test cutoffs and a lock."
  />
  <figcaption>
    The Karu64 entropy source on the FPGA. Each raw bit is one sampled ring; bits are never combined. Every k-th symbol is kept, checked by repetition-count and adaptive-proportion tests per lane, and four symbols form one 16-bit <code>seed</code> word.
  </figcaption>
</figure>

Bits are never combined or whitened in hardware. That is a deliberate choice: each lane remains one physical process of the kind modelled in [_On Entropy and Bit Patterns of Ring Oscillator Jitter_](https://arxiv.org/abs/2102.02196), with a frequency, a duty cycle and a jitter variance per sample. So each lane can be measured and checked against that model, instead of being hidden behind a conditioner. Two custom M-mode CSRs support this:
- `mnoise` (`0x7C8`) is the GetNoise test interface suggested in the Zkr rationale. It returns raw symbols, with a flag for lost samples.
- `mentropycfg` (`0x7C9`) sets the decimation and the health-test cutoffs, and can be locked until reset.

### How OpenSBI and Linux pick it up

Zkr is advertised like any other ISA extension: as `zkr` in the device tree's `riscv,isa-extensions`. OpenSBI v1.9 reads it and sets `mseccfg.SSEED`, so that the kernel may use `seed`. Linux lists the extension, and its `archrandom` code then reads `seed` at early boot and at every reseed of the random pool. From the board's console and `/proc/cpuinfo` on 2026-11-18 (long lines shortened):

```text
OpenSBI v1.9
Platform Reboot Device      : syscon-reboot
Boot HART ISA Extensions    : smstateen,…,zihpm,zkr,smcntrpmf,…,v,f,d
…
Linux version 7.4.0-rc3-zvk-dirty …
Kernel command line: … random.trust_cpu=off
…
random: crng init done

root@karudeb:~# grep -m1 isa /proc/cpuinfo
isa		: rv64imafdcbvh_zicbom_…_zba_zbb_zbs_zkr_zkt_zvbb_…_svpbmt
```

The kernel command line has `random.trust_cpu=off`. Linux still mixes what `seed` delivers into its pool, but does not count it as entropy until the source has been characterised.

The first raw captures on the board, 10^6 symbols at each of six decimations, show what is expected and nothing more:
- each ring has a small fixed bias (its ones fraction is 0.485 to 0.498);
- the health tests stay far from their cutoffs;
- no dependence between lanes was detected.

At one sample per 256 clocks, successive samples are largely decorrelated. Two lanes still show small lag-1 autocorrelation at `k = 1`, but the captures do not provide enough information to fit the jitter model. The next step is a burst-capture mode that samples every clock cycle, for a proper characterisation.

## RISC-V Debug 1.0

**karudbg** is a Debug Module that targets the ratified RISC-V Debug Specification 1.0, for a single hart:
- execution-based debugging through a debug ROM and an eight-word Program Buffer;
- optional abstract-command autoexec;
- two `mcontrol6` address triggers, for hardware breakpoints and watchpoints, including restart of vector loads and stores;
- System Bus Access, to physical memory and devices.

On the VCU118 the debug transport goes through the FPGA's own JTAG port, a nested TAP behind the `USER4` instruction. So an unmodified OpenOCD and GDB work over the board's standard USB-JTAG cable, with no extra pins. Debug is opt-in: a build without it is unchanged, and the full debug configuration adds 0.81 % to the core's NanGate45 area.

On the board, the debugger phases cover:
- run control and single-stepping in every privilege mode, M, S, U, VS and VU;
- the complete FP and vector register state;
- hardware breakpoints and watchpoints;
- SBA while the hart runs;
- a ten-minute soak;
- a breakpoint in the running Linux kernel.

After the debugger detaches, Linux boots and passes the usual acceptance tests.

## Debug authentication

Unrestricted JTAG access is full machine-mode control of the hart. Debug 1.0 provides the hooks for authentication (`dmstatus.authenticated`, `authbusy` and the `authdata` register) but leaves the protocol to the implementation. Karu's mechanism:
- **Lifecycle.** A part is `OPEN`, `AUTH` or `DISABLED`. While locked, the Debug Module shows nothing but its version and the `authdata` mailbox, and ignores every other write.
- **Island ROM.** At power-on the hart starts in a small authentication ROM. On request, it runs one challenge–response exchange with the debugger.
- **Nonce.** The challenge carries a fresh 256-bit nonce read from `seed`.
- **One window per power-on.** If the debugger does not answer correctly within the window, the part boots on, locked. A software reboot does not reopen the window, and does not take away a grant.

<figure>
  <img
    src="/debug-auth-light.svg"
    class="no-frame dark:hidden"
    alt="Sequence diagram with the debugger, the Debug Module and the hart. The hart is held at power-on; the debugger sends REQUEST through authdata, which releases the hold; the island ROM draws a nonce from seed and sends a CHALLENGE; the debugger signs it and sends a RESPONSE; the ROM verifies it, sets the grant, closes the window and boots on; the Debug Module then reports authenticated."
  />
  <img
    src="/debug-auth-dark.svg"
    class="no-frame hidden dark:block"
    alt="Sequence diagram with the debugger, the Debug Module and the hart. The hart is held at power-on; the debugger sends REQUEST through authdata, which releases the hold; the island ROM draws a nonce from seed and sends a CHALLENGE; the debugger signs it and sends a RESPONSE; the ROM verifies it, sets the grant, closes the window and boots on; the Debug Module then reports authenticated."
  />
  <figcaption>
    Debug authentication in lifecycle <code>AUTH</code>. The window opens once per power-on and lasts 2<sup>30</sup> cycles; the nonce comes from the Zkr entropy source.
  </figcaption>
</figure>

**The FPGA version is not secure, by design.** It is a functional rehearsal of the mechanism intended for an ASIC:
- the ROM verifies a simulation-only `TEST` "signature" whose key is public;
- the lifecycle sits on DIP switches that anyone can flip;
- the entropy source is not yet characterised.

The production signature algorithm is still to be chosen; probably SLH-DSA and/or ML-DSA. On the FPGA, four DIP switches (SW12) select what an ASIC would fix in its lifecycle fuses and straps. They are read at the CPU reset button or at reconfiguration:

| SW12 | Off | On |
| --- | --- | --- |
| 1 | lifecycle `OPEN`: debug without authentication | lifecycle `AUTH` |
| 2 | — | lifecycle `DISABLED`: no debug at all |
| 3 | boot normally | in `AUTH`: hold the hart until a debugger sends a request |
| 4 | entropy source on | entropy source off: `seed` stays in `BIST` |

All off is the default: the board then behaves like an image without these features. On the board, every case passed:
- authenticate, with a fresh nonce each time;
- wrong signature, replayed response and expiry, each left the part locked;
- no hold, disabled, and the entropy source off;
- a grant, and a locked state, each survived a software reboot.

## KaruDeb: Linux 7.4-rc3 and OpenSBI v1.9

[KaruDeb](https://github.com/karucore/karudeb) moves to **Linux 7.4-rc3**, built with Clang 24. With it, the Debian userspace passes the board acceptance:
- memory, cache and vector checks;
- the kernel's AES self-tests on the vector crypto extensions;
- the vector ptrace selftests;
- the KVM tests.

The boot ROM now carries **OpenSBI v1.9** with a `syscon-reboot` device, so `reboot` works without a debugger. The board went through eight software reboots in this session, each back through the boot ROM. KaruDeb also builds a `zkr` variant of the device tree, which is the one that turns Zkr on for Linux.

## More information

- Zkr and the entropy source: [FPGA guide](https://github.com/karucore/karu64/blob/main/doc/fpga.md), [`rtl/karu_entropy.v`](https://github.com/karucore/karu64/blob/main/rtl/karu_entropy.v), [`karu_rosc_rng.v`](https://github.com/karucore/karu64/blob/main/flow/fpga/karu_rosc_rng.v) and the [follow-up plan](https://github.com/karucore/karu64/blob/main/doc/zkr-followup-plan.md).
- Debug: the [karudbg README](https://github.com/karucore/karu64/blob/main/dbg/README.md) and [area and timing measurements](https://github.com/karucore/karu64/blob/main/dbg/MEASUREMENTS.md).
- Debug authentication: the [plan](https://github.com/karucore/karu64/blob/main/doc/debug-auth-plan.md) and the [contract](https://github.com/karucore/karu64/blob/main/doc/debug-auth-contract.md).
- The [board acceptance record of 2026-11-18](https://github.com/karucore/karu64/blob/main/dbg/BOARD_ACCEPTANCE-2026-11-18.md).
- KaruDeb's [Linux 7.4-rc3 kernel acceptance record](https://github.com/karucore/karudeb/blob/main/doc/kernel-7.4-rc3-20261117.md).
