# IPv4 Parsing: Having Your Cake and Eating It Too

## Requirements

- [Zig](https://ziglang.org/download/) 0.17.0
- An x86_64 CPU with `BMI2`, `SSE4.1` and `AVX2` (Haswell / Zen 1 or newer)
- Linux with glibc (the benchmark checks every parser against `inet_pton` and times glibc's `strlen` and `memcpy`)

## Running the benchmark

```
zig build benchmark
```

For steadier numbers, pin it to a single core:

```
taskset -c 3 zig build benchmark
```

Expected output, on an i7-7700K:

```
info: Parsing 1500000 random IPs 64 times (1274.88MB)
info: bmi (len given)            4.35 ns/ip   3.05 GB/s
info: simdzone (overreads)       4.76 ns/ip   2.79 GB/s
info: hybrid (len given)         3.30 ns/ip   4.03 GB/s
info: --- no length, no overread ---
info: hybrid + strlen            5.64 ns/ip   2.35 GB/s
info: simdzone + memcpy         16.34 ns/ip   0.81 GB/s
info: simdzone + strlen, regs    8.83 ns/ip   1.50 GB/s
```

Code layout alone can move a row by a few tenths of a nanosecond between builds, so run it a few times before reading too much into small gaps.

## Running the tests

```
zig build test
```

Besides the malformed-input and fuzz tests, this round-trips all 2^32 addresses through every parser, so expect it to take around 10 minutes.

## Files

- `hybridParseIPV4.zig`: the hybrid parser (`AVX2` + `pext`)
- `bmiParseIPV4.zig`: the scalar parser (`pext` + `pdep`)
- `simdzoneIp4.c`: simdzone's `SSE` parser, copied from upstream
- `simdzoneRegs.c`: C adapters for simdzone, including the in-bounds variants
- `benchmark.zig`, `test.zig`, `build.zig`: the benchmark, the tests and the build script
