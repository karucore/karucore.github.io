---
author: Markku-Juhani O. Saarinen
pubDatetime: 2026-06-22T00:00:00.000Z
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

I was happy to notice that the stock OpenSSL 3.5.6 currently shipped with RISC-V Debian (trixie) already has comprehensive support for the Zvk vector crypto extensions. Well, this shouldn't be so surprising -- they were already ratified already in 2023. For more information about these extensions, see  [Chapter 33 of the Unprivileged ISA spec](https://docs.riscv.org/reference/isa/v20260120/unpriv/vector-crypto.html).

##	The OpenSSL ``Processor Capabilities Vector''

OpenSSL uses the [RISC-V processor capabilities vector](https://docs.openssl.org/3.6/man3/OPENSSL_riscvcap/) to specify processor capabilities available on a given system. The library can **dynamically** load implementations optimized for your specific processor variant. Not just RISC-V processors but also ARM, Intel, PowerPC, ... CPUs have similar capability vectors, as additional cryptographic capabilities have been added to those ISAs over time.

On any given machine, you can dump the string from the command line with `openssl info -cpusettings`. With the current Karu64, you get:
```
karu@karudeb:~$ openssl info -cpusettings
OPENSSL_riscvcap=RV64GC_ZBA_ZBB_ZBS_ZKT_V_ZVKB_ZVKG_ZVKNED_ZVKNHA_ZVKNHB_ZVKSED_ZVKSH vlen:256
```
The capabilities OpenSSL reports for Karu (at the time of writing) are:

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

Linux *does* also know about `Zvkt` (Vector DIEL) -- as can be seen from `/proc/cpuinfo` -- but OpenSSL doesn't seem to have that separately. In any case, Karu itself implements both *"constant-time"* extensions, which means that a specific subset of cryptography and non-cryptography instructions always has data-independent execution latency.


> [!note]
> Karu doesn't support many *[Scalar Cryptography](https://docs.riscv.org/reference/isa/v20260120/unpriv/scalar-crypto.html)* extensions (`Zk..` rather than `Zvk..`) as are mostly superseded by the vector equivalents in [RVA23U64](https://docs.riscv.org/reference/rva23/v1.0/rva23-profiles.html).
> Back in 2020, I helped write a [paper](https://doi.org/10.46586/tches.v2021.i1.109-136) on the design process for these non-vector symmetric cryptography extensions. Already then, it was clear that Vector Cryptography would be more relevant to application-class processors, and scalar for low-end microcontrollers. The development of vector extensions was a continuation of scalar work in the RISC-V Crypto TG in 2020-23 (with stronger involvement from Ken Dockser and a few additional folks). I don't think that a separate academic write-up exists for it.
> However, the current Karu has a serious gap: it lacks the `Zkr` *[Entropy Source](https://docs.riscv.org/reference/isa/v20260120/unpriv/scalar-crypto.html#crypto_scalar_es)* extension for true random bits. The entropy source extension is shared between vector and scalar cryptography, and its design rationale is documented in this [paper](https://doi.org/10.1007/s13389-021-00275-6) ([free e-Print](https://eprint.iacr.org/2020/866.pdf)) that appeared in different versions from 2020 to 2022.

##	You can set capabilities dynamically -- on command line!

The OpenSSL command-line utility (of the same name) can pick up the capability string from an environment variable, so we can pass it on the command line and study the effect of various extensions on performance.

Let's pass simply the base `rv64gc` (base) ISA string to the built-in benchmark function for AES-128:
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

The KaruDeb repo includes an automated script `openssl_zvk_bench` that runs this test on relevant ciphers. Here are some summary numbers from my first run. These are wall-clock timings measured by the standard `openssl` `speed` command on the 75 MHz FPGA board running Linux 7.1.1 (with full MMU and DDR4 memory overhead):

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

>[!tip]
> We also use the `openssl` command-line utility for additional end-to-end known-answer tests (KATs) for its symmetric crypto implementations; this script is `openssl_zvk_kat`.
