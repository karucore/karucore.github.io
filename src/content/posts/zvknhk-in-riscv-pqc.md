---
author: Markku-Juhani O. Saarinen
pubDatetime: 2026-09-11T10:54:35.000Z
title: Zvknhk Moves to the Official RISC-V PQC Repository
featured: true
draft: false
tags:
  - riscv
  - pqc
  - zvknhk
  - qemu
  - openssl
  - karu64
  - karudeb
description: "RISC-V PQC v0.1 is available with its Zvknhk specification, Spike, QEMU, OpenSSL, and test support, and Karu has moved to the new encoding."
---

Version 0.1 of the **RISC-V Post-Quantum Cryptography specification**, including the draft Zvknhk Vector Keccak extension, is now available as a [stable PDF](https://github.com/riscv/riscv-pqc/releases/download/v0.1/riscv-pqc-v0.1-20260911.pdf). The [specification source and supporting software](https://github.com/riscv/riscv-pqc) are maintained together in the official RISC-V International repository.

Note that earlier development locations for the specification, Spike patches, and tests are being marked as historical.

## Building the Specification

Clone the repository with its document resources and run the standard build:

```sh
git clone https://github.com/riscv/riscv-pqc.git
cd riscv-pqc
git submodule update --init docs-resources
make build
```

The build uses the RISC-V documentation container when Docker is available, or local AsciiDoctor tools otherwise, and writes the PDF and HTML documents under `build/`.

## Simulator and OpenSSL Support

The same repository now contains [Spike, QEMU, OpenSSL, and conformance-test support](https://github.com/riscv/riscv-pqc/tree/main/zvknhk). In particular, Zvknhk is available in both user-mode and system-mode QEMU; the official [QEMU build and run instructions](https://github.com/riscv/riscv-pqc/blob/main/zvknhk/qemu/README.md) cover the setup and test targets.

[Karu64](https://github.com/karucore/karu64) implements the new encoding and fixed-group semantics and matches the official Spike and QEMU models. [KaruDeb](https://github.com/karucore/karudeb) now builds the repository's Zvknhk-enabled OpenSSL and PQC benchmarks, runs them under the official QEMU support, and packages them for execution on Karu hardware.

Our updated [PQC and Keccak on Karu](/posts/pqc-and-keccak-on-karu/) article has the encoding changes and performance background.
