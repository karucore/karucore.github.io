---
author: Markku-Juhani O. Saarinen
pubDatetime: 2026-06-21T09:00:00.000Z
title: Announcing karu64 and karudeb
featured: true
draft: false
tags:
  - riscv
  - karu64
  - karudeb
  - release
description: First public release of the karu64 RV64 core and the karudeb Debian riscv64 distribution that boots Linux on it.
---

**`karu64`** is a new RV64 Application core, with a focus on supporting the RVA23U64 application profile as well as the latest Cryptography extensions from RISC-V International. We implemented Karu CPU in portable Verilog, and it is released under a permissive (BSD 3-Clause) license.

The Linux baseline is RV64GCV (RV64IMAFDCV + Zicsr + Zifencei, RVV 1.0 with Zvl256b), with M/S/U privilege, Sv39 translation, generic CLINT/PLIC/NS16550 platform services (interrupts and serial console). We also have full Zvkt (vector cryptography) extensions and Keccak available. 

Today, we're opening up two GitHub repos that together take a RISC-V core from RTL all the way to a Debian shell prompt. 

* [**karu64**](https://github.com/karucore/karu64) is a RVA23U64 - compliant RISC-V Vector core and FPGA bring-up tree — a single-issue, in-order RV64IMAFDC design with M/S/U privilege, Sv39 translation, IEEE 754 single- and double-precision floating point, and vector plus vector-crypto (Zvk) execution, targeting a VCU118 DDR4 SoC.
* [**karudeb**](https://github.com/karucore/karudeb) is the Debian `riscv64` NFS-root distribution scaffolding that builds the kernels, device trees, and root filesystems which boot Linux on that core, on real VCU118 hardware and under QEMU.

These two repos allow you to boot and SSH into the RISC-V system running on the VCU118 UltraScale+ board running at 75 MHz. The board has 2GB of DDR4 memory, accessible from Linux. There is no mass storage -- files (including boot images) are served from the connected host over NFS over the local Ethernet connection.

<figure>
  <img
    src="/ssh-login.png"
    alt="SSH login to Debian riscv64 running on the karu64 core"
  />
  <figcaption>
    An SSH session into Debian riscv64, booted on the karu64 core on a VCU118
    board.
  </figcaption>
</figure>

From the README:

For testing on the [VCU118](https://www.amd.com/en/products/adaptive-socs-and-fpgas/evaluation-boards/vcu118.html) (Xilinx UltraScale+ FPGA) target, we instantiate a SoC with Xilinx DDR4 IP components for 2 GB of memory and [LiteEth/LiteX](https://github.com/enjoy-digital/liteeth) for a basic Gbit Ethernet that supports network boot and a filesystem.

The Linux/rootfs images, DTBs, kernel builds, and deployment artifacts are produced by the companion `karudeb` repository. The core, its flows, and the FPGA SoC are documented under [doc/](doc/) — see the Documentation section below.

The core is split into IFU, decoder, ALU, M (multiply/divide), FPU (single- and double-precision IEEE 754), LSU, CSR/privilege/MMU, register files, and vector execute blocks, all behind AXI4 instruction/data memory ports. The repository also carries freestanding firmware, Verilator and Icarus testbenches, VCU118 FPGA flows, Yosys/OpenSTA NanGate45 flows, and runners for riscv-tests, TestFloat, vector/crypto tests, and OpenSBI/Linux simulation.

<!-- More to come — write the rest here. -->
