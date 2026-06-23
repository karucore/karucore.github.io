---
author: Markku-Juhani O. Saarinen
pubDatetime: 2026-06-23T00:00:00.000Z
title: PQC and Keccak on Karu
featured: true
draft: false
tags:
  - riscv
  - pqc
  - keccak
  - ml-kem
  - ml-dsa
description: Evaluating the impact of the Keccak extension on PQC (ML-KEM and ML-DSA) performance on Karu
---

**Here at [Manse Processors](https://mjos.fi/), we have been working on Post-Quantum  Cryptography since 2015!**

_Well, I was actually in [Belfast](https://www.qub.ac.uk/research-centres/csit/) doing my final post-doc then, and thanks to Prof. Máire & Co I can now claim "10+ years of PQC experience". Anyway, let me try to explain what RISC-V PQC TG currently plans to do about PQC first.._

>[!NOTE]
>**TLDR;** The Keccak instruction `vkeccak.vi` proposed in PQC TG in RISC-V International is implemented in our [karu64](https://github.com/karucore/karu64) core and makes standard lattice-based PQC algorithms go 50% faster. The more you optimize the rest, the bigger the Keccak share becomes and the greater the relative benefit of Keccak.


##	PQC Standards vs Keccak

It turns out that cryptographic hash functions (the actual subject matter of my 2009 PhD) are incredibly important for PQC. From a practical viewpoint, the two main PQC algorithms are:

* [FIPS 203](https://doi.org/10.6028/NIST.FIPS.203) _"Module-Lattice-Based Key-Encapsulation Mechanism Standard"_ (ML-KEM) is the recommended PQC key establishment method.
* [FIPS 204](https://doi.org/10.6028/NIST.FIPS.204) 
_"Module-Lattice-Based Digital Signature Standard"_ (ML-DSA) is the recommended PQC authentication and integrity protection method.

Basic quantitative analysis of ML-KEM and ML-DSA reveals that often more than 50% of their execution time is actually spent computing the KECCAK-p[1600, 24] permutation, the core of the SHAKE extensible-output function (XOF). SHAKE is specified as a part of the SHA-3 standard [FIPS 202](http://dx.doi.org/10.6028/NIST.FIPS.202).

Intuitively, you wouldn't necessarily expect this -- symmetric cryptography "support" functions consume a negligible percentage of cycles in traditional asymmetric RSA and Elliptic Curve cryptography. For the most part, ML-KEM and ML-DSA are _not_ using SHAKE to hash (_"absorb"_) input data, but to expand (_"squeeze"_) random bits for various purposes.

Naturally, the hash-based signature algorithms [SLH-DSA (FIPS 205)](https://doi.org/10.6028/NIST.FIPS.205) and [LMS & XMSS (SP 800-208)](https://doi.org/10.6028/NIST.SP.800-208) consist almost exclusively of hash computation, so any Keccak speed-up is proportionally reflected on the performance of the SHAKE parameter sets of these algorithms.


##	Keccak is Hard to Vectorize

Nicolas Brunie (SiFive) wrote a blog post about [RVV Implementation of Keccak / SHA-3](https://open.substack.com/pub/fprox/p/rvv-implementation-of-keccak-sha?utm_campaign=post-expanded-share&utm_medium=web) with a subtitle  _"Leveraging RISC-V Vector to slow down SHA-3 software implementation"_. Why?

The Keccak permutation has a very efficient mixing transformation; the downside is that the particular access pattern of words makes efficient vectorization difficult. Since all 25 state words fit into the register file simultaneously, fast scalar execution is generally faster. 
<figure>
  <img
    src="/keccak-light.svg"
    class="no-frame dark:hidden"
    alt="Main steps of the Keccak permutation."
  />
  <img
    src="/keccak-dark.svg"
    class="no-frame hidden dark:block"
    alt="Main steps of the Keccak permutation."
  />
  <figcaption>
  The Keccak permutation operates on a 5×5 = 25 words, each 64 bits; a total of 1600 bits. Each of 24 rounds is a composition of steps A<sub>i+1</sub> = χ(π(ρ(θ(A<sub>i</sub>)))) ⊕ rc<sub>i</sub>.
  </figcaption>
</figure>

The linear mixing step Theta (θ) is just `xor`s and the Rho (ρ) step is just rotations; that's why the availability of scalar `rori` makes a lot of difference for scalar Keccak speed. The word permutation PI (π) is just scalar register re-indexing, while the only nonlinear step Chi (χ) is a logical and operation with other input inverted; the bitmanip instruction `andn`. The cost of a full 24-round permutation ends up being at 3000+ instructions; in practice, the compilers emit 4000+ instructions if `rori` and `andn` are available (bitmanip extension), and 6000+ if they are not (regular RV64GC).

One can, of course, _parallelize_ VLEN/64 independent Keccak permutations with the vector unit. ML-KEM and ML-DSA can utilize such parallelism for some operations. The speedup is significantly reduced because vector instructions are generally not issued at the same rate as scalar instructions.


##	Keccak in Pure Hardware: Very, very fast

The structure is very fast in pure hardware, allowing 1 or 2 rounds per cycle even at very high operating frequencies. This is because the _logical depth_ of each round is small; each round has only a handful of gates between input and output. Note that steps Rho (ρ) and PI (π) are just wiring; no gates.

While fast, the permutation is not very small; the [cycle-per-round implementation](https://github.com/karucore/karu64/blob/main/rtl/zvk/keccak_round.v) in Karu is roughly 30 kGE, the size of a very small microcontroller core. However, for application processors, the exceptional, typically 100-fold, difference in hardware and software speed makes it sensible to do the entire permutation with a single instruction.

Hence, the main proposal from the [RISC-V Post-Quantum Cryptography Task Group](https://riscv.atlassian.net/wiki/spaces/PQC/overview) is a single instruction, _Vector-Immediate Multi-Round Keccak_, with preliminary mnemonic `vkeccak.vi`. 


While the permutation itself is easily 24 cycles, that is not the latency of the permutation due to the way vector register files are organized. A typical implementation will spend several times as much time getting data to and from the VRF as on the permutation itself. However, even if the permutation takes 100 cycles, it's still orders of magnitude faster than executing thousands of instructions. 


##	`vkeccak`: Specification Status

The implemented variant of the instruction performs Keccak in place -- in register vd. The 5-bit immediate value specifies the number of rounds. This allows both SHA-3 functions and variants such as [KangarooTwelve and TurboSHAKE](https://www.rfc-editor.org/info/rfc9861/) to be implemented.

```
vkeccak.vi vd, imm5
```

The main proposal is that the source/destination register vd specify a LMUL = 2048/VLEN sized register group. In Karu, we have VLEN=256, and hence LMUL=8. The 25-word Keccak state 00 .. 24 can be mapped into 4 possible locations (vector register groups of size LMUL=8).; vd can be { V0, V8, V16, V24 }:

```
 V0: [00 01 02 03]   V1: [04 05 06 07]   V2: [08 09 10 11]   V3: [12 13 14 15]
 V4: [16 17 18 19]   V5: [20 21 22 23]   V6: [24 -- -- --]   V7: [-- -- -- --]

 V8: [00 01 02 03]   V9: [04 05 06 07]  V10: [08 09 10 11]  V11: [12 13 14 15]
V12: [16 17 18 19]  V13: [20 21 22 23]  V14: [24 -- -- --]  V15: [-- -- -- --]

V16: [00 01 02 03]  V17: [04 05 06 07]  V18: [08 09 10 11]  V19: [12 13 14 15]
V20: [16 17 18 19]  V21: [20 21 22 23]  V22: [24 -- -- --]  V23: [-- -- -- --]

V24: [00 01 02 03]  V25: [04 05 06 07]  V26: [08 09 10 11]  V27: [12 13 14 15]
V28: [16 17 18 19]  V29: [20 21 22 23]  V30: [24 -- -- --]  V31: [-- -- -- --]
```

There is a draft specification: [zvknhk.adoc](https://github.com/mjosaarinen/riscv-isa-manual/blob/main/src/zvknhk.adoc), also rendered as Chapter 31 here: [riscv-spec.pdf](https://raw.githubusercontent.com/mjosaarinen/rv-vkeccak-dev/refs/heads/main/riscv-spec.pdf). Furthermore, a private repo [keccak-xrv](https://github.com/mjosaarinen/keccak-xrv) provides tests for the instruction that can be run with a [patched version of the Spike](https://github.com/mjosaarinen/riscv-isa-sim/tree/dev-keccak) golden model/simulator.


### Open and Semi-Open Issues

There are some open issues regarding how the 1600-bit state is mapped to the vector register file across various physical vector register sizes (VLEN).

* For VLEN=256 and higher, the situation is relatively straightforward; ceil(1600/VLEN) registers are required; 7 registers for VLEN=256 and 4 registers with VLEN=512, etc. These fit into normal register group sizes. However, VLEN=128 is problematic: 13 registers are required, exceeding the maximum register group size, LMUL=8. This could be resolved simply by considering the group size being _implicit_ for the Keccak instruction. From an implementation viewpoint, the FSM (or similar) for accessing the VRF is likely unique to it in any case.

* A further question is whether any 5-bit number of rounds should be admissible. Allowing any intermediate can make a highly optimized implementation that computes double-rounds or even triple-rounds (per cycle) potentially more difficult to implement. In practice, the Keccak permutation is used only with 12 or 24 rounds, which could be expressed with a single bit (for _"Keccak"_ and _"TurboKeccak"_) and leaving an additional 4 bits reserved for other use.

* There is also the question of whether vector register V0 should be avoided for some VLEN sizes, as it also serves as the mask register.


## Benchmarking PQC Code

Our [ML-KEM and ML-DSA implementations](https://github.com/karucore/karudeb/tree/main/tools/pqc) in KaruDeb have been derived from the original "ANSI C" Kyber and Dilithium code, with some modifications and options.

*	There is a central macro flag for the Keccak permutation that is implemented alternatively with the Keccak instruction (`VK_KECCAK == 1`) or with a reasonably fast scalar code (`VK_KECCAK == 0`).

*	The RISC-V Autovectorizer in recent versions of LLVM works really for some targets, but unfortunately it doesn't know that our vector unit is relatively slow compared to the scalar ALU. The C code was compiled with the clang cross-compiler version 23.0.0git, which I built on June 1, 2026 (commit c07f4eef0945cf8e3b1d7480cbfcfa19f79d885f). There was no special target tuning; simply `-O3` flag is used, and architecture flags specify which extensions are allowed. 

*	Certain parts have hand-written vector intrinsics optimizations controlled by flags `MLDSA_RVV == 1` and `MLKEM_RVV == 1`. This is especially relevant for the shuffles in the Number Theoretic Transforms (`vrgather` shuffle instruction) and for rejection sampling in the A matrix generation (`vcompress`). The code is currently limited to our VLEN = 256 size, and may not be the final word in ML-KEM and ML-DSA optimization, but it still beats LLVM & GCC autovectorization in most cases.

*	In these implementations, different parameter sets share the same execution paths, eliminating the need to re-instantiate multiple full versions of the algorithms for different security levels. This may make implementations slightly slower due to compiler optimizations (fewer opportunities to embed constants in instruction immediates, etc.), but it was originally done for code size and to simplify the build flow.

*	The cycle counts are read with the standard RISC-V `rdcycles` instruction. Especially in a multi-user or multi-core Linux system, this register may be filtered/managed. The KaruDeb has a little utility for that: [perf_run.c](https://github.com/karucore/karudeb/blob/main/tools/perf_run.c) opens Linux perf events and then execs the actual benchmark binary (and its parameters) from the command line.

>[!WARNING]
>Even though these implementations pass the basic [NIST ACVP KAT](https://github.com/usnistgov/ACVP-Server/tree/master/gen-val/json-files) and hence are functionally correct _99.9% of the time_, their implementation assurance level is nowhere near projects such as [PQ Code Package](https://github.com/pq-code-package). So, at present, they are intended only for performance testing.


## Results

Here we are giving some raw cycle numbers; you can see that Karu is not as fast as most other processors (its CPI -- the average cycles/instruction number when running general benchmarks such as CoreMark is higher than on many microcontrollers). That wasn't our goal with this single-issue in-order CPU that doesn't even have proper caches; we wanted to achieve feature completeness while still fitting a full application vector processor in an FPGA. In absolute terms, these numbers tell nothing about "RISC-V" -- if I built a processor like this with x86 or ARM ISA, it would have an equally bad CPI.

Hence, "speed" is computed as before-cycles / after-cycles _on the same target_, so 1.00x means the same speed, and values above 1.00x mean the second build is faster. Averages are arithmetic means over the nine top-level operations for each algorithm.

If you are interested in instruction counts rather than cycle counts (which _are_ purely ISA dependent), you can obtain those offline using the spike simulator and the test matrix scripts for [ML-KEM](https://github.com/karucore/karudeb/blob/main/tools/pqc/mlkem/test_matrix.sh) and [ML-DSA](https://github.com/karucore/karudeb/blob/main/tools/pqc/mldsa/test_matrix.sh).


###	Impact of Scalar Bitmanip Alone (+15%)

_(Simply enabling the Zbb flag in the compiler. This is almost entirely thanks to RORI and ANDN making Keccak faster.)_

**ML-KEM**: RV64GC vs RV64GC+Zbb

| Parameter          | Operation | Before cycles | After cycles |     Speed |
| ------------------ | --------- | ------------: | -----------: | --------: |
| ML-KEM-512         | KeyGen    |     2,295,030 |    1,966,678 |     1.17x |
| ML-KEM-512         | Encaps    |     2,662,499 |    2,360,391 |     1.13x |
| ML-KEM-512         | Decaps    |     3,380,772 |    3,054,179 |     1.11x |
| ML-KEM-768         | KeyGen    |     3,820,038 |    3,300,756 |     1.16x |
| ML-KEM-768         | Encaps    |     4,415,354 |    3,902,175 |     1.13x |
| ML-KEM-768         | Decaps    |     5,364,660 |    4,828,285 |     1.11x |
| ML-KEM-1024        | KeyGen    |     6,033,467 |    5,215,560 |     1.16x |
| ML-KEM-1024        | Encaps    |     6,612,651 |    5,796,009 |     1.14x |
| ML-KEM-1024        | Decaps    |     7,823,228 |    6,997,590 |     1.12x |
| **ML-KEM average** |           |               |              | **1.14x** |

**ML-DSA**: RV64GC vs RV64GC+Zbb

| Parameter          | Operation | Before cycles | After cycles |     Speed |
| ------------------ | --------- | ------------: | -----------: | --------: |
| ML-DSA-44          | KeyGen    |     7,338,818 |    6,188,665 |     1.19x |
| ML-DSA-44          | Sign      |    19,964,933 |   18,210,571 |     1.10x |
| ML-DSA-44          | Verify    |     7,889,854 |    6,772,220 |     1.17x |
| ML-DSA-65          | KeyGen    |    12,625,934 |   10,479,449 |     1.20x |
| ML-DSA-65          | Sign      |    39,670,452 |   36,420,314 |     1.09x |
| ML-DSA-65          | Verify    |    13,024,223 |   11,005,438 |     1.18x |
| ML-DSA-87          | KeyGen    |    21,264,381 |   17,715,313 |     1.20x |
| ML-DSA-87          | Sign      |    47,264,050 |   42,618,207 |     1.11x |
| ML-DSA-87          | Verify    |    21,955,096 |   18,462,775 |     1.19x |
| **ML-DSA average** |           |               |              | **1.16x** |


### Impact of Keccak without Intrinsics (+40%)

_(Autovectorization in use, no intrinsics. No modification to source code except addition of Keccak instruction.)_

**ML-KEM**: RV64GCV+Zbb vs RV64GCV+Keccak

| Parameter          | Operation | Before cycles | After cycles |     Speed |
| ------------------ | --------- | ------------: | -----------: | --------: |
| ML-KEM-512         | KeyGen    |     2,253,970 |    1,569,681 |     1.44x |
| ML-KEM-512         | Encaps    |     2,804,064 |    2,136,533 |     1.31x |
| ML-KEM-512         | Decaps    |     3,701,594 |    3,028,184 |     1.22x |
| ML-KEM-768         | KeyGen    |     3,858,323 |    2,762,166 |     1.40x |
| ML-KEM-768         | Encaps    |     4,604,880 |    3,461,625 |     1.33x |
| ML-KEM-768         | Decaps    |     5,801,337 |    4,665,072 |     1.24x |
| ML-KEM-1024        | KeyGen    |     6,025,810 |    4,253,128 |     1.42x |
| ML-KEM-1024        | Encaps    |     6,903,974 |    5,091,228 |     1.36x |
| ML-KEM-1024        | Decaps    |     8,425,032 |    6,622,388 |     1.27x |
| **ML-KEM average** |           |               |              | **1.33x** |

**ML-DSA**: RV64GCV+Zbb vs RV64GCV+Keccak

| Parameter          | Operation | Before cycles | After cycles |     Speed |
| ------------------ | --------- | ------------: | -----------: | --------: |
| ML-DSA-44          | KeyGen    |     6,819,445 |    4,253,936 |     1.60x |
| ML-DSA-44          | Sign      |    23,335,515 |   19,444,154 |     1.20x |
| ML-DSA-44          | Verify    |     7,876,425 |    5,447,570 |     1.45x |
| ML-DSA-65          | KeyGen    |    11,369,397 |    6,740,834 |     1.69x |
| ML-DSA-65          | Sign      |    46,010,689 |   38,785,842 |     1.19x |
| ML-DSA-65          | Verify    |    12,515,502 |    8,232,686 |     1.52x |
| ML-DSA-87          | KeyGen    |    18,805,211 |   10,811,598 |     1.74x |
| ML-DSA-87          | Sign      |    52,663,308 |   42,433,698 |     1.24x |
| ML-DSA-87          | Verify    |    20,369,042 |   12,719,756 |     1.60x |
| **ML-DSA average** |           |               |              | **1.47x** |


###	Impact of Intrinsics alone (+25%)

_(No Keccak instruction. Impact of my optimizations with vector intrinsics over autovectorization.)_

**ML-KEM**: RV64GCV+Zbb vs RV64GCV+Zbb+Intrin

| Parameter          | Operation | Before cycles | After cycles |     Speed |
| ------------------ | --------- | ------------: | -----------: | --------: |
| ML-KEM-512         | KeyGen    |     2,253,970 |    1,815,728 |     1.24x |
| ML-KEM-512         | Encaps    |     2,804,064 |    2,164,385 |     1.30x |
| ML-KEM-512         | Decaps    |     3,701,594 |    2,811,828 |     1.32x |
| ML-KEM-768         | KeyGen    |     3,858,323 |    2,996,183 |     1.29x |
| ML-KEM-768         | Encaps    |     4,604,880 |    3,465,683 |     1.33x |
| ML-KEM-768         | Decaps    |     5,801,337 |    4,328,674 |     1.34x |
| ML-KEM-1024        | KeyGen    |     6,025,810 |    4,619,065 |     1.30x |
| ML-KEM-1024        | Encaps    |     6,903,974 |    5,167,511 |     1.34x |
| ML-KEM-1024        | Decaps    |     8,425,032 |    6,257,855 |     1.35x |
| **ML-KEM average** |           |               |              | **1.31x** |

**ML-DSA**: RV64GCV+Zbb vs RV64GCV+Zbb+Intrin

| Parameter          | Operation | Before cycles | After cycles |     Speed |
| ------------------ | --------- | ------------: | -----------: | --------: |
| ML-DSA-44          | KeyGen    |     6,819,445 |    6,033,446 |     1.13x |
| ML-DSA-44          | Sign      |    23,335,515 |   18,163,803 |     1.28x |
| ML-DSA-44          | Verify    |     7,876,425 |    6,675,913 |     1.18x |
| ML-DSA-65          | KeyGen    |    11,369,397 |   10,282,689 |     1.11x |
| ML-DSA-65          | Sign      |    46,010,689 |   36,023,519 |     1.28x |
| ML-DSA-65          | Verify    |    12,515,502 |   10,828,080 |     1.16x |
| ML-DSA-87          | KeyGen    |    18,805,211 |   17,248,740 |     1.09x |
| ML-DSA-87          | Sign      |    52,663,308 |   42,379,474 |     1.24x |
| ML-DSA-87          | Verify    |    20,369,042 |   18,061,301 |     1.13x |
| **ML-DSA average** |           |               |              | **1.18x** |


### With Vector Intrinsics: Impact of Keccak (+52%)

_(This is the headline number. With vector intrinsics the relative share of Keccak cycles increases, so the impact of the Keccak instruction is larger.)_

**ML-KEM**: RV64GCV+Zbb+Intrin vs RV64GCV+Intrin+Keccak

| Parameter          | Operation | Before cycles | After cycles |     Speed |
| ------------------ | --------- | ------------: | -----------: | --------: |
| ML-KEM-512         | KeyGen    |     1,815,728 |    1,156,131 |     1.57x |
| ML-KEM-512         | Encaps    |     2,164,385 |    1,516,204 |     1.43x |
| ML-KEM-512         | Decaps    |     2,811,828 |    2,164,080 |     1.30x |
| ML-KEM-768         | KeyGen    |     2,996,183 |    1,934,499 |     1.55x |
| ML-KEM-768         | Encaps    |     3,465,683 |    2,384,597 |     1.45x |
| ML-KEM-768         | Decaps    |     4,328,674 |    3,248,962 |     1.33x |
| ML-KEM-1024        | KeyGen    |     4,619,065 |    2,925,985 |     1.58x |
| ML-KEM-1024        | Encaps    |     5,167,511 |    3,439,038 |     1.50x |
| ML-KEM-1024        | Decaps    |     6,257,855 |    4,550,838 |     1.38x |
| **ML-KEM average** |           |               |              | **1.45x** |

**ML-DSA**: RV64GCV+Zbb+Intrin vs RV64GCV+Intrin+Keccak

| Parameter          | Operation | Before cycles | After cycles |     Speed |
| ------------------ | --------- | ------------: | -----------: | --------: |
| ML-DSA-44          | KeyGen    |     6,033,446 |    3,442,754 |     1.75x |
| ML-DSA-44          | Sign      |    18,163,803 |   14,196,803 |     1.28x |
| ML-DSA-44          | Verify    |     6,675,913 |    4,218,008 |     1.58x |
| ML-DSA-65          | KeyGen    |    10,282,689 |    5,572,035 |     1.85x |
| ML-DSA-65          | Sign      |    36,023,519 |   28,784,995 |     1.25x |
| ML-DSA-65          | Verify    |    10,828,080 |    6,564,131 |     1.65x |
| ML-DSA-87          | KeyGen    |    17,248,740 |    9,112,433 |     1.89x |
| ML-DSA-87          | Sign      |    42,379,474 |   32,177,514 |     1.32x |
| ML-DSA-87          | Verify    |    18,061,301 |   10,303,710 |     1.75x |
| **ML-DSA average** |           |               |              | **1.59x** |


