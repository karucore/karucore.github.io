---
author: Markku-Juhani O. Saarinen
pubDatetime: 2026-06-22T12:00:00.000Z
title: Benchmarking (Stock) OpenSSL on Karu
featured: true
draft: false
tags:
  - riscv
  - karu64
  - openssl
  - cryptography
description: Benchmarking stock OpenSSL on Karu with its Zvk cryptography extensions.
---

[OpenSSL](https://openssl.org/) is the de facto standard cryptographic library for Linux systems. Hence, it is natural to use it for benchmarking the impact of our basic cryptographic features.

I was very happy to notice that the stock OpenSSL 3.5.6 shipped with RISC-V Debian (trixie) already has comprehensive support for the Zvk vector crypto extensions. Well, this shouldn't be so surprising -- they were ratified in 2023, and are now fully supported in both GCC and LLVM toolchains. For more information about these extensions, see  [Chapter 33 of the Unprivileged ISA spec](https://docs.riscv.org/reference/isa/v20260120/unpriv/vector-crypto.html).

##	OpenSSL ``Processor Capabilities Vector''

OpenSSL supports a thing called the [RISC-V processor capabilities vector](https://docs.openssl.org/3.6/man3/OPENSSL_riscvcap/), which specifies the processor capabilities available on a system. The library can **dynamically** load implementations optimized for your specific processor (ARM, Intel, PowerPC, ... CPUs have similar capability vectors.)

On any given machine, you can dump the string from the command line. With the current Karu64, you get:
```
karu@karudeb:~$ openssl info -cpusettings
OPENSSL_riscvcap=RV64GC_ZBA_ZBB_ZBS_ZKT_V_ZVKB_ZVKG_ZVKNED_ZVKNHA_ZVKNHB_ZVKSED_ZVKSH vlen:256
```
The capabilities of Karu (at the time of writing) decipher as:

|**String**| **Description**                               |
|----------|-----------------------------------------------|
| RV64GC   | Generic 64-bit ISA with Floating Point.       |
| Zba      | Address Generation (scalar).                  |
| Zbb      | Basic bit-manipulation (Scalar).              |
| Zbs      | Single-bit instructions.                      |
| Zkt      | Data Independent Execution Latency (DIEL).    |
| V        | Vector Extension for Application Processors.  |
| Zvkb     | Vector Cryptography Bit-manipulation.         |
| Zvkg     | Vector GCM (AEAD mode) and GHASH.             |
| Zvkned   | Vector AES Block Cipher.                      |
| Zvknha   | Vector SHA-256 Secure Hash.                   |
| Zvknhb   | Vector SHA-512 Secure Hash.                   |
| Zvksed   | Vector SM4 Block Cipher.                      |
| Zvksh    | Vector SM3 Secure Hash.                       |
| VLEN     | Physical vector register size.                |

Linux does know about `Zvkt` (Vector DIEL) -- as can be seen from `/proc/cpuinfo` -- but OpenSSL doesn't have that separately. Anyway, Karu implements and asserts both "constant-time" extensions.

However, Karu doesn't support many *Scalar Cryptography* extensions (`Zk..` rather than `Zvk..`) as these were superseded by the vector equivalents in [RVA23U64](https://docs.riscv.org/reference/rva23/v1.0/rva23-profiles.html).

> [!note]
> We published a [paper](https://doi.org/10.46586/tches.v2021.i1.109-136) on the design of scalar cryptography extensions back in 2020; the vector extensions were largely a continuation of that work in the RISC-V Crypto TG, with stronger involvement from Ken Dockser and a few additional folks. However, I don't think anyone has written a paper specifically on that design process.

##	You can set it dynamically -- on command line!

The OpenSSL command-line utility (of the same name) actually picks up the capability string from the environment, so we can pass it on the command line and study the effect of various extensions on performance.

Let's pass simply the base `rv64gc` ISA string to get the
```
karu@karudeb:~$ OPENSSL_riscvcap=rv64gc openssl speed -bytes 16384 -evp aes-128-ecb
```

The result is decidedly unimpressive, even for a processor running at 75 MHz, quite possibly because constant-time implementation of AES requires a lot of overhead when AES extensions are not available:
```
Doing AES-128-ECB ops for 3s on 16384 size blocks: 36 AES-128-ECB ops in 2.96s
version: 3.5.6
built on: Mon May  4 18:39:11 2026 UTC
options: bn(64,64)
compiler: gcc -fPIC -pthread -Wa,--noexecstack -Wall -fzero-call-used-regs=used-gpr -Wa,--noexecstack -g -O2 -Werror=implicit-function-declaration -ffile-prefix-map=/build/reproducible-path/openssl-3.5.6=. -fstack-protector-strong -Wformat -Werror=format-security -DOPENSSL_USE_NODELETE -DOPENSSL_PIC -DOPENSSL_BUILDING_OPENSSL -DZLIB -DZSTD -DNDEBUG -Wdate-time -D_FORTIFY_SOURCE=2
CPUINFO: OPENSSL_riscvcap=RV64GC env:rv64gc
The 'numbers' are in 1000s of bytes per second processed.
type          16384 bytes
AES-128-ECB        199.26k
```
Now the same with vector AES extension `Zvkned`:

```
karu@karudeb:~$ OPENSSL_riscvcap=rv64gc_v_zvkned openssl speed -bytes 16384 -evp aes-128-ecb
[...]
The 'numbers' are in 1000s of bytes per second processed.
type          16384 bytes
AES-128-ECB       6564.63k
```
So, plain AES operations are 6564.63 / 199.26 = 33 times faster with the extension!
(On this run -- there is some variance with such a 3-second test.)

##	Initial OpenSSL Benchmarks

The KaruDeb repo includes an automated script `openssl_zvk_bench` that runs this test on relevant ciphers. We also use the command-line utility for additional end-to-end known-answer tests (KATs); this script is `openssl_zvk_kat`.

| Case | Algorithm | scalar kB/s | Best cap set | Best kB/s | Best speedup |
|---|---|---:|---|---:|---:|
| aes-128-ecb | AES-128-ECB | 196.2 | `zvkb_zvkned` | 6553.6 | 33.40x |
| aes-128-ctr | AES-128-CTR | 170.1 | `zvkb_zvkned` | 5589.0 | 32.87x |
| aes-128-gcm | AES-128-GCM | 124.8 | `zvkb_zvkg_zvkned` | 4203.6 | 33.69x |
| aes-128-xts | AES-128-XTS | 169.6 | `zvkned` | 825.8 | 4.87x |
| ghash | ghash | 382.2 | `zvkg` | 14455.9 | 37.82x |
| sha256 | sha256 | 209.5 | `zvkb_zvknha` | 2414.2 | 11.52x |
| sha512 | sha512 | 372.8 | `zvkb_zvknhb` | 2077.1 | 5.57x |
| sm3 | sm3 | 194.4 | `zvkb_zvksh` | 1553.3 | 7.99x |
| sm4-ecb | SM4-ECB | 222.6 | `zvkb_zvksed` | 1784.8 | 8.02x |
| chacha20 | ChaCha20 | 403.4 | `v_zbb_zvkb` | 1363.7 | 3.38x |

Even though we write "Best cap set", there is no harm in having all of the capabilities enabled simultaneously.

