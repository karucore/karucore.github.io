---
author: Markku-Juhani O. Saarinen and Thomas Szymkowiak
pubDatetime: 2026-09-19T12:00:00.000Z
title: "Karu64: An Open RVA23S64 Processor with Vector Keccak Support"
featured: true
draft: false
tags:
  - riscv
  - karu64
  - rva23
  - pqc
  - keccak
  - zvknhk
  - ml-kem
  - ml-dsa
  - fpga
ogImage: ../../assets/images/karu64-rva23-vector-keccak-og.png
description: "A fresh, self-contained write-up following the internal review release of RISC-V PQC / Keccak Extension and recent updates to Karu64: new, faster benchmarks and RVA23S64 profile support."
---

>[!NOTE]
>**TL,DR;** A fresh, self-contained write-up following the internal review release of RISC-V PQC / Keccak Extension and recent updates to Karu64: new, faster benchmarks and RVA23S64 profile support.

>[!ABSTRACT]
>Can a whole-permutation Keccak instruction provide useful post-quantum acceleration inside a general-purpose vector application processor, despite its 1600-bit state and limited register-file bandwidth? We present, to our knowledge, the first hardware implementation of the standards-track RISC-V Zvknhk Vector Keccak extension. We integrate it alongside other vector cryptography support into Karu64, a new open-source application processor supporting the RVA23S64 profile. The complete system boots Debian Linux on a VCU118 FPGA at 75 MHz, allowing realistic OpenSSL benchmarking. Architecturally, the vkeccak.vi instruction gathers the state once, performs the permutation, and returns it through existing vector registers. This gives it excellent performance and allows usage from unmodified Linux userspace. In ideal-memory RTL simulation, resident-state SHAKE128/256 absorption and squeezing are 79–83× and 105–116× faster, respectively, than Clang-generated vector-enabled C with Zbb and Zvbb extensions. FPGA measurements under Linux show end-to-end ML-KEM and ML-DSA operations gain 1.48× and 1.65×, respectively, over hand-vectorized implementations, due to the central role of Keccak in these PQC standards. A NanGate45 synthesis comparison shows a 2.29 % core-area increment over the implemented ratified-crypto baseline. These results establish practical feasibility of the fixed-group instruction, connecting standards-track semantics to integrated hardware cost and measured application benefit in a working Linux system.

## Table of contents

## Introduction

The transition to the ML-KEM[^NI24A] and ML-DSA[^NI24B] quantum-safe cryptographic standards profoundly affects the nature of cryptographic compute workloads. "Big integer modular arithmetic" is no longer dominant; the cost is now split between polynomial arithmetic and SHA-3/SHAKE, which supplies hashing, seed expansion, and sampling streams. Optimizing only the Number Theoretic Transform (NTT) and other polynomial operations in these Lattice-based algorithms therefore leaves a substantial symmetric-cryptography cost; roughly half of the cycles on many platforms.

SHA-3 and SHAKE are _sponge modes_ built from the 1600-bit Keccak-_p_[1600,24] permutation[^NI15]. Software vectorization significantly accelerates polynomial operations, but cross-lane movement makes Keccak relatively hard to vectorize[^ZhYaHu25]. In pure hardware, the Keccak permutation is very fast and comparatively simple to implement. The recognized architectural challenge is moving a 1600-bit state efficiently between the application and that hardware.

The ratified RVA23 application profiles[^RI24B] provide a long-term compatibility target; they reduce software porting and maintenance effort, and facilitate binary software distribution. For example, Ubuntu Linux has required RVA23S64 since release 25.10[^Ca26], and RVA23 is also the baseline for RISC-V Android ABI[^RI24C]. Vector extensions V, Zvbb, and Zvkt are mandatory in RVA23, while the vector-cryptography suites Zvkng and Zvksg[^RI26] are options. Our stock OpenSSL results ([below](#symmetric-cryptography-with-stock-openssl)) demonstrate the benefit of ecosystem support already available for ratified vector cryptography extensions.

Researchers have previously designed custom RISC-V Keccak Instruction Set Extensions (ISEs), including round-step instructions[^LiMePi23]<sup>,</sup>[^BoSeMc25], a scalar extension with private permutation state[^CaPaPa26], and tightly coupled coprocessors[^DoPiMi25]<sup>,</sup>[^DoPiHu26]. While many of these are open source, they have not been submitted to RISC-V International for ratification consideration.

In September 2026, the RISC-V PQC Task Group released [version 0.1 of its specification](https://github.com/riscv/riscv-pqc/releases) with the Zvknhk Vector Keccak extension[^RI26B], whose single instruction `vkeccak.vi` performs a full 24-round (or 12-round) Keccak-_p_[1600] permutation in place on a fixed 2048-bit vector register group. Many ratification-relevant artifacts exist: A Sail specification, Spike and QEMU reference models, and middleware integration (an OpenSSL backend). However, at the time of writing, it is still a standards-track draft, not a fully ratified extension.

We evaluate this emerging architectural contract, which departs from most previous proposals in its vector-integration approach. We take a whole-systems design approach and ask whether coarse-grained acceleration remains worthwhile after operand movement and processor integration. Linux execution on FPGA exposes these costs through real virtual-memory and cache/DRAM paths, making the evaluation more realistic.

We have three main contributions:

* **A new RISC-V processor platform.** We describe Karu64, an open, size-optimized, RVA23S64 compatible vector processor that integrates the Zvknhk extension. We validate it against current references such as RISC-V ACT 4.1 (Architectural Certification Tests).
* **Evaluating the cost and benefit of Zvknhk.** FPGA measurements under Linux show 1.48× ML-KEM and 1.65× ML-DSA gains beyond vector intrinsics. Controlled synthesis places incremental Keccak integration at 87.19 kGE, or 2.29 % over Zvk. SHAKE blocks gain 79–116× over compiler-generated vector-enabled C in ideal-memory RTL simulation, and the resident permutation needs 20× fewer cycles than the best published RISC-V software[^ZhYaHu25].
* **A microarchitectural analysis.** We explain how full-permutation fusion avoids the repeated register traffic of round-step ISEs[^LiMePi23]<sup>,</sup>[^BoSeMc25], distinguishing engine latency, register transfers, and the software interface used in the measurements.

## Background and Related Work

### RISC-V Vectors and Element Groups

RVV 1.0 adds 32 vector registers of `VLEN` bits (128 ≤ `VLEN` ≤ 65536, an implementation constant); the vector length `vl` and the `vtype` CSR (element width `SEW`, group multiplier `LMUL`) determine how many elements an instruction processes. The Zvk extensions[^RI26] introduced _element groups_: an AES instruction treats four 32-bit elements as one 128-bit block (`EGW=128`, `EGS=4`); SHA-512 and SM3 use `EGW=256`.

Zvkt specifies data-independent execution latency (DIEL) for designated vector instructions. Crypto instructions avoid the secret-indexed table accesses responsible for software AES cache attacks[^BoMi06]<sup>,</sup>[^OsShTr06] and are hence "constant time".

### Keccak in Post-Quantum Cryptography

Keccak-_p_[1600,24] operates on a 5×5 array of 64-bit lanes _A_[_x_,_y_]. In software, the instruction mix of each of its 24 rounds consists of word shuffling, rotations, and logical XORs, ANDs, and NOT operations. Our RV64GC non-vector permutation needs 6601 instructions, or 4268 with Zbb's `RORI` and `ANDN` -- roughly 275 or 178 instructions per round.

Software must issue rotations and move data between registers for permutations, but those are just static wiring in a hardware round datapath; parallel XOR and AND-NOT networks implement the remaining operations. The logic depth of a Keccak round is remarkably short, allowing a 1-cycle hardware round implementation at high clock frequencies, with full permutation taking 24 cycles.

ML-KEM and ML-DSA invoke the permutation dozens to hundreds of times per operation (n̄<sub>f</sub> in the [PQC tables below](#post-quantum-cryptography-with-vkeccakvi)); A fast Keccak instruction speeds up essentially all PQC operations.

### Related Work

Zhang et al.[^ZhYaHu25] demonstrate the importance of optimized software baselines for Keccak and lattice cryptography on RISC-V. Arm's four SHA-3 helper instructions (`EOR3`, `RAX1`, `XAR`, `BCAX`)[^AR26] fuse two or three primitive operations on 128-bit registers; around 30 instructions are needed per round.

RISC-V Keccak ISEs differ mainly in where the 1600-bit state lives and in how much of the permutation one instruction performs. Li et al.[^LiMePi23] add custom round-step vector instructions with a Keccak-oriented register layout on an Alveo U250 FPGA at 100 MHz; their best 64-bit configuration takes 75 cycles per round, and PQC integration is left as future work. Bolat et al.[^BoSeMc25] execute one round per `shatr` instruction, prototyped on CVA6, holding the state in dedicated internal registers. PQCUARK[^CaPaPa26] is a scalar extension whose two-rounds-per-cycle engine keeps a private state behind the load/store unit and moves it through memory in 64-bit words; on the Sargantana RV64 core it gains 2.3× over optimized ML-KEM/ML-DSA software, with a 1028 kGE Keccak unit in GF22. Coprocessors attached through CV-X-IF[^DoPiMi25]<sup>,</sup>[^DoPiHu26] mirror the state in a private register file and complete a permutation call in 385–553 cycles on 32-bit microcontrollers; related designs target code-based schemes[^DoDiVa25]<sup>,</sup>[^DoPiMa26]. None of these proposals are on the RISC-V standards track -- full upstream compiler, emulator, or distribution support is unlikely.

### Application Processor and Linux Integration

Most cited proposals (except Li et al.[^LiMePi23]) store the internal Keccak state in a manner which is not architecturally-visible; the state must be saved/restored using custom kernel code or confined to single-threaded, bare-metal execution. Zvknhk stores the state within a fixed group of architectural vector registers, supporting the existing vector context switch, signal delivery and trap semantics used within Linux. This is what allows us to use it from unmodified Debian Linux userspace. Our distinction is hence the combination of the standards-track Zvknhk ISA contract, an RVA23-targeted vector application processor, Linux execution, and end-to-end gains after vectorizing lattice arithmetic.

## The Zvknhk Vector Keccak Extension

The Keccak extension Zvknhk[^RI26B] depends on the RISC-V vector extension baseline with `VLEN` ≥ 128 and defines a single instruction, `vkeccak.vi vd, imm5`. Its design reflects the hardware/software asymmetry above.

<figure>
  <img
    src="/vkeccak-encoding-light.svg"
    class="no-frame dark:hidden"
    alt="Instruction encoding of vkeccak.vi: funct6=101001, vm=1, imm5 (rounds), selector=10010, funct3=010, vd (in-out), opcode OP-VE=1110111."
  />
  <img
    src="/vkeccak-encoding-dark.svg"
    class="no-frame hidden dark:block"
    alt="Instruction encoding of vkeccak.vi: funct6=101001, vm=1, imm5 (rounds), selector=10010, funct3=010, vd (in-out), opcode OP-VE=1110111."
  />
  <figcaption>
    Encoding of <code>vkeccak.vi</code> in Zvknhk draft v0.1. Bit 31 is on the left; OP-VE is <code>0x77</code>. The <code>vd</code> field selects the in-place fixed register group, and <code>imm5</code> selects 24 rounds or the last 12 rounds. Other immediates and <code>vm=0</code> are reserved.
  </figcaption>
</figure>

The figure shows the concrete instruction encoding: the round selector occupies the usual `vs2` field, and `10010` selects Keccak in the vector-crypto opcode space. For example, `vkeccak.vi v0, 0` permutes the state in the group starting at `v0`, using all 24 rounds.

**Whole permutation, not rounds.** Because a round is cheap and shallow in hardware, the instruction performs all 24 rounds (`imm5=0`: Keccak-_f_[1600] as used by SHA-3, SHAKE, ML-KEM, ML-DSA, and SLH-DSA) or the last 12 rounds with constants _RC_[12..23] (`imm5=1`: Keccak-_p_[1600,12] as used by TurboSHAKE and KangarooTwelve[^ViWoVa25]); other immediates are reserved. Vector register file traffic -- the expensive part -- is thus paid once per permutation, and the internal round rate is an implementation choice.

**One fixed element group.** The 1600-bit state does not fit the Zvk convention of a _vector of_ element groups strip-mined by `vl`. Instead the instruction operates on a group of `EGS=32` 64-bit elements (`EGW=2048`) at `vd`, spanning `NREG = ceil(2048/VLEN)` consecutive registers (16 at `VLEN=128`, 8 at 256, 4 at 512, one at ≥ 2048). The group is independent of `vl` (including `vl=0`) and `LMUL` and exempt from the `EGS ≤ VLMAX` and `EMUL ≤ 8` rules; software only selects `SEW=64`. Elements 0–24 hold _A_[_x_,_y_] at index _x_+5_y_; elements 25–31, the _state tail_, and all other register bits are preserved.

**Reserved encodings, atomicity, DIEL.** `SEW ≠ 64`, a misaligned `vd`, `vm=0`, and a nonzero `vstart` raise an illegal-instruction exception; the group update must be atomic with respect to traps, and execution latency must be data-independent.

**Architectural state and software integration.** The instruction has no persistent architectural state outside the vector registers. State can be transferred by plain unit-stride `vle64`/`vse64`, and `vxor` can be used for block absorption.

## The Karu64 Core

Karu64 is a single-issue, in-order RV64GCV core written in portable Verilog-2001 and released under the BSD 3-Clause license (Karu64 RTL source, flows, HW tests: [github.com/karucore/karu64](https://github.com/karucore/karu64)). Its main development priorities were RVA23 feature completeness, portability, and compact size -- not raw performance. The main OS target is Linux; we use Debian for tests (Karu's Debian drivers, benchmarks: [github.com/karucore/karudeb](https://github.com/karucore/karudeb)).

### From Marian to Karu64

Our original intention was to implement the standards-track Keccak extension within an existing open-source core for system evaluation. However, we found that the available open-source candidates were not suitable for full system evaluation. For instance, CVA6/Ara[^PeCaAn24] is lacking full RVV 1.0 compliance and provides no MMU support for vector operations. This, and the desire to run standard RVA23 Linux software on an FPGA, motivated us to develop the Karu64 vector core using only a small number of pre-existing hardware components:

Marian[^SzIsSa24] integrated ratified Zvk cryptography into a CVA6/Ara[^PeCaAn24] vector subsystem using operand collection, cryptographic execution, and writeback stages. Karu64 reuses its AES, SHA-2, SM3, and SM4 logic, with several adaptations. A new GHASH engine replaces Marian's combinational implementation. We adopt the Keccak round RTL from the Sloth SLH-DSA accelerator[^Sa24].

Controlled use of Large Language Models (see [Acknowledgment](#acknowledgment) section) to write RTL, together with the availability of the RISC-V Sail specification, ACT 4.1, and other open specification/certification infrastructure greatly accelerated development.

Architecturally, Marian demonstrated the complications of retrofitting the 128- or 256-bit element groups required by standard Vector Cryptography into an existing lane-oriented vector architecture. Our relatively simple (but feature-complete) vector unit was designed from the start to facilitate ratified Zvk extensions and the proposed 1600-bit Keccak vector groups.

### Scalar Core and Privilege Architecture

A prefetcher with an optional 4 KiB instruction cache feeds the decoder and instruction data is subsequently registered for execution; a `busy` signal from the multi-cycle execution units prevents further instructions from being issued before the currently executing instruction is retired. The units include the integer ALU, Zba/Zbb/Zbs, configurable multiply/divide, IEEE 754 single/double FPUs with fused multiply-add, atomic load/store, and vector execution. The evaluated configuration implements the mandatory RVA23S64 feature set: the user baseline including full Zvbb, privileged-1.13 CSRs, Sv39/Svade, Svnapot, Svpbmt, Svinval, Sstc, Sscofpmf, and H/Sha with two-stage translation and state enables[^RI24B]<sup>,</sup>[^RI26]<sup>,</sup>[^RI26A]. Furthermore, CLINT/PLIC supports OpenSBI and Linux; optional Smcntrpmf enables privilege-filtered fixed counters (for benchmarks). Scalar multiply/divide use 4/64 cycles and vector multiply/divide 16/64 cycles, with two vector pipeline stages.

### Vector Unit

The vector register file (VRF) is a dual-port memory, accessed in 128-bit _granules_ with exact byte enables, realizing RVV "undisturbed" policies without whole-register read-modify-write.

At `VLEN=256`, each vector register contains four 64-bit elements; the measured configuration processes granules through two 64-bit SIMD lanes, both with floating-point support. A unified sequencer implements reductions, permutations (`vrgather`, `vcompress`, slides), and fixed-point arithmetic. The vector load/store unit supports all RVV addressing modes with precise page faults through the shared Sv39 MMU.

### Zvk Crypto Unit

Because a 64-bit lane cannot present a 128- or 256-bit element group atomically, Zvk instructions execute outside the lanes: the sequencer gathers the operand groups from the VRF, pulses a request to one isolated crypto unit containing adapted AES, SHA-2, SM3, SM4, and GHASH datapaths behind a uniform request/busy/done handshake, and writes the result group back. AES is combinational with a registered output; SHA-2 compression and message instruction schedules take two and four cycles; SM4 iterates its four rounds one per cycle; GHASH uses a radix-2<sup>8</sup> iterative multiplier (16 cycles) in place of Marian's combinational 128-stage carry-less multiplier; Zvkb is ordinary lane logic. All datapaths have data-independent latency, and the core advertises Zvkt.

### The `vkeccak.vi` Datapath

<figure>
  <img
    src="/karu64-arch-light.svg"
    class="no-frame dark:hidden"
    alt="Karu64 architectural overview: fetch/decode/single-issue control on top; scalar execution and scalar LSU on the left; the vector unit with sequencer, vector registers, RVV lanes, Zvk crypto, the Zvknhk engine, and the vector load/store unit on the right; the shared data subsystem at the bottom."
  />
  <img
    src="/karu64-arch-dark.svg"
    class="no-frame hidden dark:block"
    alt="Karu64 architectural overview: fetch/decode/single-issue control on top; scalar execution and scalar LSU on the left; the vector unit with sequencer, vector registers, RVV lanes, Zvk crypto, the Zvknhk engine, and the vector load/store unit on the right; the shared data subsystem at the bottom."
  />
  <figcaption>
    Karu64 architectural overview. Dashed arrows denote issue; solid arrows denote operand/result or memory transfers. Zvk and Keccak are shared engines outside the RVV lanes. The highlighted Zvknhk path combines a sequencer-held 2048-bit buffer with one 1600-bit round engine. Instruction-memory, page-table-walk, and detailed control wiring are omitted.
  </figcaption>
</figure>

The Keccak instruction reuses this pattern with a larger operand. At issue, reserved encodings and invalid configuration trap without side effects. Otherwise, a sub-FSM _loads_ the eight registers into a 2048-bit buffer, _runs_ the permutation on bits 0–1599 for 24 or 12 rounds, and _stores_ the registers back, preserving tail bits 1600–2047. Reload uses both BRAM ports to fetch a whole 256-bit register per fill. The round datapath implements the FIPS 202 mappings with LFSR-generated ι constants; a 12-round run starts at _RC_[12]. One engine serves all lanes. No register is written before permutation completion, and no trap interrupts writeback, making the update atomic. The buffer is reloaded on each instruction invocation; there is no persistent Keccak shadow. For 24 rounds, the core engine has a 25-cycle request-to-completion latency; this excludes VRF movement and sequencing.

On FPGA, a permutation loop benchmark measures 88 cycles for a full 24-round permutation, including those costs, loop control, and amortized counter overhead (see [SHAKE throughput](#resident-state-shake-throughput)).

### Functional Verification

We tested architectural compliance using ACT 4.1 (RISC-V Architectural Certification Tests) against Sail, supplemented by RTL assertions and directed microarchitectural tests. Directed tests cover two-stage translation, timers, counter filtering, vector context, access faults, and AXI backpressure. Zvk checks include multi-group AES/SM4 scalar-source broadcast, and 215 operand-class DIEL checks pass with the FPGA pipeline settings. Keccak tests cover 12 and 24 rounds, dependencies, fixed groups, tails, and illegal cases. Separate simulated SHAKE tests check independent `hashlib` known answers across multiple blocks, byte alignments 0–15, page boundaries, and injected stalls. We also ran AI-powered security, correctness, and standards compliance reviews of the source code.

On the measured FPGA image, Linux memory, vector ABI, crypto, and KVM API acceptance pass; the supplied stock-OpenSSL capture records 92/92 known-answer comparisons.

## Implementation Results

### FPGA System and Linux

The evaluation system is a Xilinx VCU118 (Virtex UltraScale+ XCVU9P) with 2 GiB DDR4, LiteEth gigabit Ethernet, UART, and a boot ROM. OpenSBI 1.8.1 and U-Boot 2025.01 boot Linux 7.2.4 with a Debian "trixie" NFS root. All reported FPGA benchmarks use the same RVA23S64 image. Vivado 2026.1 reports 366 098 CLB LUTs, 86 857 registers, 317.5 BRAM tiles, and 29 DSPs for the complete SoC. At 75 MHz, the CPU and whole-design timing closes cleanly. Linux programs exercise vector and crypto instructions through real virtual memory, caches, and DDR.

### Area

| Configuration          | Total (kGE) | Δ (kGE) | Keccak bucket (kGE) |
| ---------------------- | ----------: | ------: | ------------------: |
| RV64GCV+Zvbb           |     3667.90 |      -- |                  -- |
| + Zvk                  |     3806.98 | +139.08 |                  -- |
| + Zvk + Zvknhk         |     3894.17 | +226.27 |               31.20 |
| FPGA CPU configuration |     4390.60 |      -- |               31.20 |

_Yosys/NanGate45 area-only comparison. Δ is the complete-core cell-area change from RV64GCV+Zvbb. The final row includes the profile, I-cache, and FPGA pipeline/counter options._

The table uses controlled Yosys 0.69+24/NanGate45 mapping, fast ABC, and disabled sharing; NAND2 area is 0.798 µm², and 200 MHz target. Here memories map into cells, without memory compilers or physical design.

The CPU configuration used for FPGA tests maps to 4.391 MGE, including profile and pipeline options; its difference from the feature baseline is not a Keccak-only cost. In the Yosys flow we observe that Zvknhk adds 87.19 kGE (2.29 %) over the Zvk feature baseline. The nested round-engine hierarchy is 31.20 kGE: the complete-core delta also captures buffering, control, and mapping changes.

## Performance Evaluation

The FPGA dataset measures resident SHAKE, ML-KEM/ML-DSA, and stock OpenSSL on one 75 MHz bitstream and Linux installation. The whole-process perf totals are not per-operation timings. ML-KEM rows average 100 operations and ML-DSA rows 10; mean speedups are arithmetic means of nine per-operation ratios per algorithm.

SHAKE reports the best repeated loop average; OpenSSL measures wall-clock throughput. Here "resident state" indicates an integration where the Keccak state stays in the vector registers between permutation iterations when absorbing or squeezing, rather than being fully transferred to/from memory for each permutation -- as in "wrappers". (A Keccak instruction wrapper is a simple drop-in integration technique for software that uses Keccak APIs that pass permutation input/output in memory. This results in some memory-vector access overhead.)

### Resident-State SHAKE Throughput

| Implementation             | Absorb 168 B | Absorb 136 B | Squeeze 168 B | Squeeze 136 B |
| -------------------------- | -----------: | -----------: | ------------: | ------------: |
| RV64GC C                   |        25390 |        25414 |         24653 |         24970 |
| + Zbb                      |        16572 |        16163 |         16059 |         16348 |
| + Zbb + V + Zvbb           |        17497 |        16385 |         16459 |         16804 |
| RTL resident `vkeccak.vi`  |       221.75 |       197.75 |        156.88 |        144.56 |
| _RTL gain vs. vector C_    |    **78.9×** |    **82.9×** |    **104.9×** |    **116.2×** |
| FPGA, 16 blocks            |       242.50 |       224.12 |        286.31 |        257.56 |
| FPGA, 256 blocks           |       306.64 |       274.94 |        292.44 |        260.15 |

_Cycles per SHAKE rate block, including permutation. Rates 168/136 B correspond to SHAKE128/256. Upper rows: ideal-memory Verilator, 16-block averages; Clang 22.1.8 `-O3` C. Lower rows: FPGA loop averages, best of 21 runs for 16 blocks and 7 runs for 256 blocks. Gains compare simulation rows only._

Both environments use `VLEN=256`. State remains in `v0`–`v7`; absorption loads a rate block, XORs, and permutes, while squeezing stores a rate block and permutes. Setup/spill, padding, and checking are outside timing; pointer and counter overhead remain. A finite _N_-block squeeze needs _N_−1 permutations; these steady-state loops retain the final permutation. The FPGA harness uses an assembly loop and warms input before measurement. Its 16- and 256-block results retain their different working sets and repetition counts, rather than being pooled. The resident permutation costs 87.62/87.98 cycles and a load–permute–store loop costs 394.75/395.70 cycles for 16/256 blocks. These include loop overhead and differ from the instrumented PQC wrapper below.

The ideal simulation benchmark has data L1 enabled and instruction caching disabled. Data cache, VRF, and AXI protocol costs remain; vector pipelines match the FPGA geometry, while scalar multiply/divide retain one-cycle simulation defaults. Hardware unrolls 16 steps. The C baselines inline the portable permutation into a rolled 16-block loop, permitting register residency. The 79–83× absorption and 105–116× squeezing gains apply to compiler-generated vector-enabled C.

In the controlled simulation comparison, transfer optimizations reduce absorption cycles by 39.5/44.9 % and squeezing by 46.3/47.2 % (168/136 B). The resident permutation drops from 135.06 to 79.06 cycles through operand-movement changes around an unchanged round engine. The FPGA rows report their integrated behavior with the updated profile and real memory system.

The fastest published RISC-V software permutation we are aware of, Zhang et al.'s hand-scheduled RV64IB assembly on the dual-issue XuanTie C908[^ZhYaHu25], takes 1770 cycles and 3405 instructions; their RVV variant is slower than their scalar code. In cycle count, the 88-cycle resident permutation is 20× below that best published RISC-V software permutation and 55× below their 4827-cycle C908 RVV implementation, at very different clock rates.

### Wrapper Performance on Karu64

The PQC wrapper interface loads and stores 25 state words at `LMUL=8`, with `vkeccak.vi`, vector configuration, a VLEN check, and a call counter. The ML-KEM microbenchmark averages 500 cycles and 18 retired instructions for this wrapper, versus 24 316 cycles for software Keccak in the intrinsics/Zbb build (48.6×). This instrumented memory-to-memory interface is distinct from the resident-state loop and the simpler 395.70-cycle load–permute–store loop. Its transfer latencies are part of the end-to-end benchmarks.

The large cycle-count gains reflect both permutation fusion and the relatively low throughput of general-purpose instructions on our core. Our Zbb build retires 4268 instructions per permutation, matching the 4296 that Zhang et al.[^ZhYaHu25] report for compiled C on RV64IB and about 25 % more than their best hand-written RV64IB assembly (at CPI 0.52 on the dual-issue XuanTie C908), whereas the RV64GC rows of the SHAKE table run at roughly four cycles per instruction in our much simpler processor.

### Symmetric Cryptography with Stock OpenSSL

| Algorithm   | Extensions used  | Scalar (kB/s) | Zvk (kB/s) | Speedup |
| ----------- | ---------------- | ------------: | ---------: | ------: |
| AES-128-ECB | Zvkned           |         196.2 |    7,523.8 |   38.3× |
| AES-128-CTR | Zvkb+Zvkned      |         174.8 |    6,267.7 |   35.9× |
| AES-128-GCM | Zvkb+Zvkg+Zvkned |         127.4 |    4,655.8 |   36.5× |
| AES-128-XTS | Zvbb+Zvkg+Zvkned |         167.8 |    5,610.3 |   33.4× |
| GHASH       | Zvkb+Zvkg        |         382.2 |   16,551.0 |   43.3× |
| SHA-256     | Zvkb+Zvknhb      |         213.8 |    3,001.8 |   14.0× |
| SHA-512     | Zvkb+Zvknhb      |         368.4 |    2,815.2 |    7.6× |
| SM3         | Zvkb+Zvksh       |         194.0 |    1,712.0 |    8.8× |
| SM4-ECB     | Zvkb+Zvksed      |         219.6 |    2,202.6 |   10.0× |
| ChaCha20    | V+Zbb+Zvkb       |         395.6 |    1,515.0 |    3.8× |

_Wall-clock throughput of the unmodified Debian OpenSSL 3.5.7 `speed` benchmark (16 384-byte blocks, 10 s runs) on the 75 MHz board. The OpenSSL capability string is used to select extensions._

The table selects scalar and accelerated paths through runtime capability overrides in a Debian stock OpenSSL binary. AES-GCM gains 36.54×, GHASH 43.30×, SHA-256 14.04×, and SHA-512 7.64× over package scalar paths. The tested Zvbb+Zvkg+Zvkned path also raises AES-XTS to 33.44×. This demonstrates unmodified distribution-library acceleration; draft Zvknhk support in a separate patched OpenSSL backend is not part of these results.

### Post-Quantum Cryptography with `vkeccak.vi`

The following tables give ML-KEM/ML-DSA FPGA measurements under Linux: thousands of user cycles (means of 100 ML-KEM or 10 ML-DSA operations; n̄<sub>f</sub> = mean Keccak-_p_[1600,24] calls). Builds: RV64GC; +Zbb; LLVM-autovectorized RV64GCV ("V auto"); with `vkeccak.vi` ("+K"); hand-written vector intrinsics for NTT and sampling ("V intr."); and intrinsics with `vkeccak.vi`. Software-Keccak vector builds target GCV+Zbb; +K builds target GCV with the wrapper. The final column is the incremental speedup from V intr. to V intr.+K.

**ML-KEM** (thousands of cycles)

<div class="overflow-x-auto">

| Parameter                     | Op.    | n̄<sub>f</sub> | RV64GC | +Zbb   | V auto | V auto+K | V intr. | V intr.+K | K gain    |
| ----------------------------- | ------ | ------------: | -----: | -----: | -----: | -------: | ------: | --------: | --------: |
| ML-KEM-512                    | KeyGen |            27 | 2275.9 | 1974.7 | 2073.8 |   1386.4 |  1715.9 |    1059.2 | **1.62×** |
| ML-KEM-512                    | Encaps |            26 | 2645.5 | 2370.5 | 2579.2 |   1933.4 |  2034.7 |    1403.8 | **1.45×** |
| ML-KEM-512                    | Decaps |            26 | 3373.6 | 3102.2 | 3379.2 |   2726.8 |  2635.4 |    2014.5 | **1.31×** |
| ML-KEM-768                    | KeyGen |            43 | 3780.7 | 3315.1 | 3554.7 |   2483.0 |  2825.9 |    1773.4 | **1.59×** |
| ML-KEM-768                    | Encaps |            44 | 4399.0 | 3913.5 | 4247.8 |   3143.2 |  3263.3 |    2198.8 | **1.48×** |
| ML-KEM-768                    | Decaps |            44 | 5366.1 | 4897.5 | 5336.5 |   4218.6 |  4059.5 |    3015.5 | **1.35×** |
| ML-KEM-1024                   | KeyGen |            69 | 5971.8 | 5227.6 | 5575.0 |   3850.7 |  4368.6 |    2680.2 | **1.63×** |
| ML-KEM-1024                   | Encaps |            70 | 6580.9 | 5811.9 | 6399.1 |   4654.4 |  4867.2 |    3182.7 | **1.53×** |
| ML-KEM-1024                   | Decaps |            70 | 7813.0 | 7051.4 | 7777.7 |   6008.5 |  5892.1 |    4216.5 | **1.40×** |
| _ML-KEM mean speedup vs. GC_  |        |               | **1.00×** | **1.12×** | **1.04×** | **1.41×** | **1.33×** | **1.97×** | **1.48×** |

</div>

**ML-DSA** (thousands of cycles)

<div class="overflow-x-auto">

| Parameter                     | Op.    | n̄<sub>f</sub> | RV64GC  | +Zbb    | V auto  | V auto+K | V intr. | V intr.+K | K gain    |
| ----------------------------- | ------ | ------------: | ------: | ------: | ------: | -------: | ------: | --------: | --------: |
| ML-DSA-44                     | KeyGen |           103 |  7226.7 |  6071.1 |  6353.0 |   3818.6 |  5781.1 |    3158.1 | **1.83×** |
| ML-DSA-44                     | Sign   |           158 | 19914.0 | 18135.9 | 20706.7 |  16831.0 | 16662.4 |   12860.2 | **1.30×** |
| ML-DSA-44                     | Verify |            99 |  7746.9 |  6729.6 |  7287.3 |   4750.4 |  6251.2 |    3795.7 | **1.65×** |
| ML-DSA-65                     | KeyGen |           188 | 12299.1 | 10381.1 | 10690.5 |   6110.7 |  9786.3 |    5095.8 | **1.92×** |
| ML-DSA-65                     | Sign   |           287 | 39532.1 | 36336.0 | 40928.9 |  33957.2 | 33331.1 |   26321.2 | **1.27×** |
| ML-DSA-65                     | Verify |           174 | 12752.4 | 10893.5 | 11606.4 |   7254.9 | 10199.6 |    5870.1 | **1.74×** |
| ML-DSA-87                     | KeyGen |           324 | 20992.7 | 17378.3 | 17797.8 |   9742.9 | 16494.5 |    8392.1 | **1.97×** |
| ML-DSA-87                     | Sign   |           408 | 46978.9 | 42377.0 | 47166.1 |  37147.3 | 39290.0 |   29327.1 | **1.34×** |
| ML-DSA-87                     | Verify |           311 | 21428.9 | 18229.3 | 19021.5 |  11348.7 | 17170.1 |    9334.2 | **1.84×** |
| _ML-DSA mean speedup vs. GC_  |        |               | **1.00×** | **1.15×** | **1.08×** | **1.66×** | **1.23×** | **2.04×** | **1.65×** |

</div>

The tables evaluate ML-KEM/ML-DSA derived from the reference Kyber/Dilithium C[^Ky24]<sup>,</sup>[^Di24], compiled with Clang 23 (git `c07f4eef`), `-O3`, and the specification instruction encoding. Build switches select scalar or hardware Keccak and RVV intrinsics for `vrgather`-based NTT butterflies and `vcompress`-based rejection sampling. The implementations have NIST ACVP known-answer validation. Software-Keccak vector builds target GCV+Zbb; hardware-Keccak builds target GCV with the wrapper, not an otherwise identical flag toggle.

For the ML-KEM 256-point NTT, autovectorization is slower than scalar GC (136 485 versus 121 508 cycles), while our intrinsics require 103 979 cycles (1.17× over GC). ML-DSA shows 164 367, 119 219, and 96 379 cycles, respectively (1.24× for intrinsics over GC). These results reflect this granule-sequenced implementation.

The tables show mean speedups of 1.12×/1.15× from Zbb alone for ML-KEM/ML-DSA. Default autovectorization slows both relative to scalar Zbb in our core; intrinsics improve on autovectorized software by 1.28×/1.15×. Using `vkeccak.vi` yields 1.36×/1.53× on autovectorized code and 1.48×/1.65× on intrinsics code. The latter ranges from 1.27× for ML-DSA-65 signing to 1.97× for ML-DSA-87 key generation.

Over scalar GC, the combined mean gains are 1.97×/2.04×, reaching 2.50× for ML-DSA-87 key generation. The shorter ML-DSA sample and rejection-dependent signing workload limits conclusions about its timing distribution.

For ML-KEM-768 key generation, approximately 43 permutations at 24.3 k cycles account for about 37 % of the 2.826 M-cycle intrinsics baseline. An Amdahl estimate with this share and 48.6× permutation acceleration predicts 1.57×, close to the measured 1.59×.

### Performance Comparison with Prior Keccak ISEs

Reported single-state permutation costs are 1800 cycles for 24 rounds using round-step instructions of Li et al.[^LiMePi23] (75 cycles per round at 64-bit `LMUL=8`), 385 and 553 cycles per permutation call for the CV-X-IF coprocessors[^DoPiHu26]<sup>,</sup>[^DoPiMi25], and 12 cycles for the PQCUARK engine[^CaPaPa26] before its 64-bit-word state traffic through memory, versus our 87.98-cycle FPGA resident-permutation loop including VRF transfers and loop overhead. These are cross-design cycle counts at different clocks, word widths, and measurement boundaries, not matched throughput speedups, and batched multi-state throughput[^LiMePi23] is only partially relevant to PQC usage. The controlled same-core comparison is the simulation rows of the [SHAKE table](#resident-state-shake-throughput).

## Lessons and Future Work

**Operand movement matters.** The fixed-group definition lets Karu64 gather the 1600-bit state through existing granule paths, without a shuffle network. Full-permutation fusion pays VRF traffic cost once rather than for every round-step instruction[^LiMePi23], and architectural registers avoid the per-word state transfers and operating system task-switching complexity of private-state designs[^CaPaPa26]<sup>,</sup>[^DoPiHu26].

**Prototype notes and limitations.** The current prototype supplies only preliminary feasibility evidence for Zvknhk ratification. ASIC tape-out is planned future work. We don't claim that our processor has comparable performance or verification maturity to commercial and high-end application processors. These will need further architectural considerations for Zvknhk.

## Conclusion

The standards-track Zvknhk `vkeccak.vi` instruction is practical in an open RVA23S64 vector application processor. On the 75 MHz Linux/FPGA system, a resident permutation takes approximately 88 cycles, and the instruction adds 1.48×/1.65× ML-KEM/ML-DSA gains beyond general vector intrinsics optimizations. For SHA-3 and SHAKE throughput, ideal-memory comparisons show 79–83× absorption and 105–116× squeezing gains over vector-enabled C code. Controlled synthesis places Keccak integration at 87.19 kGE, or 2.29 % over Zvk. Full-permutation fusion removes repeated round-step register traffic, while vector-register residency avoids per-block state spills. The instruction semantics, scoped hardware cost, and working Linux applications establish a concrete feasibility case for the standards-track Keccak instruction proposal.

## Acknowledgment

We thank the SoC Hub team at Tampere University and the RISC-V International Post-Quantum Cryptography Task Group for their support and discussions. Endrit Isufi provided original Marian Zvk testing and benchmarks. Our work was supported by the Horizon Europe EQUIP project.

Anthropic (Fable 5.1, Opus 5) and OpenAI (GPT-6 Astra, GPT 5.6-Sol) AI models were used under the close supervision of the authors for experiment design, drafting, and table/figure preparation.

## References

[^NI24A]: NIST, "Module-Lattice-Based Key-Encapsulation Mechanism Standard," Federal Information Processing Standards Publication [FIPS 203](https://doi.org/10.6028/NIST.FIPS.203), August 2024.
[^NI24B]: NIST, "Module-Lattice-Based Digital Signature Standard," Federal Information Processing Standards Publication [FIPS 204](https://doi.org/10.6028/NIST.FIPS.204), August 2024.
[^NI15]: NIST, "SHA-3 Standard: Permutation-Based Hash and Extendable-Output Functions," Federal Information Processing Standards Publication [FIPS 202](https://doi.org/10.6028/NIST.FIPS.202), August 2015.
[^ZhYaHu25]: J. Zhang, Y. Yan, J. Huang, and Ç. K. Koç, "Optimized Software Implementation of Keccak, Kyber, and Dilithium on RV{32,64}IM{B}{V}," _IACR Trans. Cryptogr. Hardw. Embed. Syst._, vol. 2025, no. 1, pp. 632–655, 2025. [doi:10.46586/tches.v2025.i1.632-655](https://doi.org/10.46586/TCHES.V2025.I1.632-655), [ePrint 2024/1515](https://eprint.iacr.org/2024/1515).
[^RI24B]: RISC-V International, "[RVA23 Profiles](https://docs.riscv.org/reference/rva23/_attachments/rva23-profile.pdf)," version 1.0, ratified October 17, 2024.
[^Ca26]: Canonical, "[Canonical and Ubuntu RISC-V: a 2025 retro and looking forward to 2026](https://canonical.com/blog/canonical-and-ubuntu-risc-v-a-2025-retro-and-looking-forward-to-2026)," press release, February 2026.
[^RI24C]: RISC-V International, "[RISC-V Announces Ratification of the RVA23 Profile Standard](https://riscv.org/blog/risc-v-announces-ratification-of-the-rva23-profile-standard/)," press release, October 2024.
[^RI26]: RISC-V International, "[The RISC-V Instruction Set Manual Volume I: Unprivileged Architecture](https://docs.riscv.org/reference/isa/_attachments/riscv-unprivileged.pdf)," Official Release 20260120, January 2026.
[^LiMePi23]: H. Li, N. Mentens, and S. Picek, "Maximizing the Potential of Custom RISC-V Vector Extensions for Speeding up SHA-3 Hash Functions," in _DATE 2023_, Antwerp, Belgium, April 2023, pp. 1–6. [doi:10.23919/DATE56975.2023.10137009](https://doi.org/10.23919/DATE56975.2023.10137009).
[^BoSeMc25]: A. Bolat, S. Sezer, K. McLaughlin, and H. Hui, "Microarchitecture Design and Benchmarking of Custom SHA-3 Instruction for RISC-V," in _ISVLSI 2025_, Kalamata, Greece, July 2025, pp. 1–6. [doi:10.1109/ISVLSI65124.2025.11130308](https://doi.org/10.1109/ISVLSI65124.2025.11130308), [arXiv:2508.20653](https://doi.org/10.48550/arXiv.2508.20653).
[^CaPaPa26]: X. Carril, A. M. Pasoot, E. Parisi, O. Farràs, C. A. Lara-Nino, and M. Moretó, "PQCUARK: A Scalar RISC-V ISA Extension for ML-KEM and ML-DSA," in _DATE 2026_, Verona, Italy, April 2026, pp. 1–7. [doi:10.23919/DATE69613.2026.11539512](https://doi.org/10.23919/DATE69613.2026.11539512), [ePrint 2025/2178](https://eprint.iacr.org/2025/2178).
[^DoPiMi25]: A. Dolmeta, V. Piscopo, M. Mirigaldi, M. Martina, and G. Masera, "RISC-V Based Keccak Co-Processor for NIST Post-Quantum Cryptography Standards," in _IEEE ISCAS 2025_, pp. 1–5. [doi:10.1109/ISCAS56072.2025.11043433](https://doi.org/10.1109/ISCAS56072.2025.11043433).
[^DoPiHu26]: A. Dolmeta, V. Piscopo, M. Hutter, M. Martina, and G. Masera, "HORCRUX: A Complete PQC RISC-V Extension Architecture," _CoRR_, vol. abs/2607.13939, 2026. [arXiv:2607.13939](https://doi.org/10.48550/arXiv.2607.13939).
[^RI26B]: RISC-V International, "[RISC-V Post-Quantum Cryptography Extension](https://github.com/riscv/riscv-pqc/releases/download/v0.1/riscv-pqc-v0.1-20260911.pdf)," RISC-V Post-Quantum Cryptography Task Group, development draft v0.1, September 11, 2026. Source and support software: [github.com/riscv/riscv-pqc](https://github.com/riscv/riscv-pqc).
[^BoMi06]: J. Bonneau and I. Mironov, "Cache-Collision Timing Attacks Against AES," in _CHES 2006_, LNCS vol. 4249, Springer, 2006, pp. 201–215. [doi:10.1007/11894063_16](https://doi.org/10.1007/11894063_16).
[^OsShTr06]: D. A. Osvik, A. Shamir, and E. Tromer, "Cache Attacks and Countermeasures: The Case of AES," in _CT-RSA 2006_, LNCS vol. 3860, Springer, 2006, pp. 1–20. [doi:10.1007/11605805_1](https://doi.org/10.1007/11605805_1).
[^AR26]: Arm, "[Arm A-profile A64 Instruction Set Architecture](https://support.arm.com/documentation/ddi0602/2026-06)," Guide DDI 0602, June 2026.
[^DoDiVa25]: A. Dolmeta, S. Di Matteo, E. Valea, M. Carmona, A. Loiseau, M. Martina, and G. Masera, "TYRCA: A RISC-V Tightly-Coupled Accelerator for Code-Based Cryptography," in _DATE 2025_, pp. 1–7. [doi:10.23919/DATE64628.2025.10993202](https://doi.org/10.23919/DATE64628.2025.10993202).
[^DoPiMa26]: A. Dolmeta, V. Piscopo, M. Martina, and G. Masera, "CIRCE: CROSS Integrated RISC-V Cryptographic Extension," in _DATE 2026_, pp. 1–3. [doi:10.23919/DATE69613.2026.11539337](https://doi.org/10.23919/DATE69613.2026.11539337).
[^ViWoVa25]: B. Viguier, D. Wong, G. Van Assche, Q. Dang, and J. Daemen, "KangarooTwelve and TurboSHAKE," IETF [RFC 9861](https://doi.org/10.17487/RFC9861), October 2025.
[^PeCaAn24]: M. Perotti, M. A. Cavalcante, R. Andri, L. Cavigelli, and L. Benini, "Ara2: Exploring Single- and Multi-Core Vector Processing With an Efficient RVV 1.0 Compliant Open-Source Processor," _IEEE Trans. Computers_, vol. 73, no. 7, pp. 1822–1836, 2024. [doi:10.1109/TC.2024.3388896](https://doi.org/10.1109/TC.2024.3388896).
[^SzIsSa24]: T. Szymkowiak, E. Isufi, and M.-J. Saarinen, "Poster: Marian: An Open Source RISC-V Processor with Zvk Vector Cryptography Extensions," in _ACM CCS 2024_, Salt Lake City, UT, USA, October 2024. [doi:10.1145/3658644.3691394](https://doi.org/10.1145/3658644.3691394).
[^Sa24]: M.-J. O. Saarinen, "Accelerating SLH-DSA by Two Orders of Magnitude with a Single Hash Unit," in _CRYPTO 2024_, LNCS vol. 14920, Springer, 2024, pp. 276–304. [doi:10.1007/978-3-031-68376-3_9](https://doi.org/10.1007/978-3-031-68376-3_9).
[^RI26A]: RISC-V International, "[The RISC-V Instruction Set Manual Volume II: Privileged Architecture](https://docs.riscv.org/reference/isa/_attachments/riscv-privileged.pdf)," Official Release 20260120, January 2026.
[^Ky24]: Kyber Team, "[Kyber -- Official Reference Implementation](https://github.com/pq-crystals/kyber)," 2024. Matches FIPS 203; commit 10b478f was used.
[^Di24]: Dilithium Team, "[Dilithium -- Official Reference Implementation](https://github.com/pq-crystals/dilithium/)," 2024. Matches FIPS 204; commit cbcd875 was used.
