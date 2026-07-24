# Moissanite

**Native-level kernels written as Ruby data. Silicon carbide under Ruby.**

Moissanite lets you write the native level of your program _in Ruby_ — not by compiling Ruby
syntax, and not by writing C. A kernel is an inspectable expression tree built out of ordinary Ruby
values. The same tree has two interpretations:

- a **pure-Ruby oracle** — the single source of the semantics, runs everywhere, slow
- **FFI-driven native backends** — the same tree lowered through the system C toolchain
  (`-O3`), loaded with `dlopen`, called through `Fiddle`

There is deliberately **no compiler in this gem**: no parser, no type inference over Ruby syntax,
no code generator to maintain. The tree _is_ the AST from birth, and native backends inherit
GCC/Clang's optimizer instead of reimplementing one. Correctness is not argued — it is measured:
a differential battery pins the native backends bit-for-bit to the oracle.

## Numbers (Ruby 3.3, gcc 13 `-O3`, rustc 1.94 `--release` + LTO, same algorithm, same evaluation order)

| workload                                        | moissanite                 | Rust (std, release) |
| ----------------------------------------------- | -------------------------- | ------------------- |
| mandelbrot 600×400, limit 500                   | **73 ms** (checksum equal) | 76 ms               |
| horner deg-8, runtime coefficients, per element | **1.39 ns** (specialized)  | 2.90 ns (generic)   |
| same kernel on the pure-Ruby oracle             | ~98× slower                | —                   |

Two honest readings:

- **Parity at the floor.** A kernel written as Ruby data ties `rustc -O3` on a classic numeric
  loop, with an identical checksum — because it goes through the same class of optimizer.
- **Ahead where AOT cannot follow.** The horner kernel is _built at runtime_, so coefficients
  that only exist at runtime are folded into the instruction stream before `-O3` sees them.
  A stock AOT binary must stay generic. That is a structural advantage of computation-as-data,
  and it is worth 2× here. (Rust could match it only by shipping its own JIT.)

Reproduce: `rake bench` — it runs the Ruby side and, if built, the Rust baseline with the same
coefficients (`cd bench/rust_baseline && cargo build --release`).

## Quick start

```ruby
require 'moissanite'

mandel = Moissanite.kernel(:mandel, cr: :f64, ci: :f64, limit: :i64) do |k, cr, ci, limit|
  zr = k.let(0.0)
  zi = k.let(0.0)
  n  = k.let(0)
  k.count(limit) do |i|
    t = k.let((zr * zr) - (zi * zi) + cr)
    k.assign(zi, (2.0 * zr * zi) + ci)
    k.assign(zr, t)
    k.break_if((zr * zr) + (zi * zi) > 4.0)
    k.assign(n, i + 1)
  end
  k.ret n
end

mandel.call(-0.75, 0.1, 1000)      # native if a C toolchain exists, oracle otherwise
mandel.interpret(-0.75, 0.1, 1000) # always the pure-Ruby oracle
mandel.source_c                    # inspect exactly what the cc backend emits
mandel.to_sexp                     # the kernel is data — look at it
```

The builder block is ordinary Ruby, and that is the point: `each`, `times`, conditionals and
method calls _weave_ the tree instead of executing arithmetic. Metaprogramming becomes runtime
specialization:

```ruby
coeffs = read_config_floats # known only at runtime

poly = Moissanite.kernel(:poly, out: :f64_buf, xs: :f64_buf, n: :i64) do |k, out, xs, n|
  k.count(n) do |i|
    x   = k.let(xs[i])
    acc = k.let(coeffs.first)
    coeffs.drop(1).each { |c| k.assign(acc, (acc * x) + c) } # unrolled, constants folded
    k.store(out, i, acc)
  end
  k.ret 0
end
```

Buffers are raw `double` memory shared by both levels — the oracle reads them bounds-checked,
native code receives the bare pointer:

```ruby
xs  = Moissanite::Buffer.f64([1.0, 2.0, 3.0])
out = Moissanite::Buffer.f64(3)
poly.call(out, xs, 3)
out.to_a
```

## Semantics (pinned by the oracle, enforced on backends by the differential battery)

| topic         | rule                                                                               |
| ------------- | ---------------------------------------------------------------------------------- |
| types         | `:f64` (IEEE 754 double), `:i64` (64-bit two's complement), `:bool`; `:f64_buf`    |
| i64 overflow  | wraps (backends compile with `-fwrapv`)                                            |
| i64 `/` `%`   | truncate toward zero, remainder follows the dividend (C semantics, not Ruby's)     |
| i64 `/ 0`     | oracle raises `MathError`; native is undefined — guard before dividing             |
| f64           | bit-exact with Ruby `Float` (`-ffp-contract=off`, hex-float constants)             |
| `&` `\|`      | bool-only, short-circuit in both levels                                            |
| casts         | `.to_f64`, `.to_i64` (truncates toward zero; out-of-range raises in the oracle)    |
| mixed types   | never implicit — `f64 + i64` is a build-time `TypeMismatch`                        |
| `count(n)`    | `n` evaluated once at loop entry; `break_if` exits the innermost loop              |
| buffer bounds | oracle checks and raises `IndexError`; native trusts the caller (N1: checked mode) |
| falling off   | impossible — kernels must end in `k.ret`, validated at build                       |

## Backends

Selection is a fallback chain — **it works everywhere, and is fast where it can be**:

1. `cc` — emits C from the tree, compiles `-O3 -fwrapv -ffp-contract=off` with the system
   compiler, `dlopen`s the result, calls it through `Fiddle::Function`. Artifacts are
   content-addressed by SHA-256 of the source: the same tree never compiles twice.
2. `oracle` — always available.

Environment knobs: `MOISSANITE_BACKEND=oracle|cc` (force), `MOISSANITE_CC` (compiler),
`MOISSANITE_CACHE_DIR` (artifact cache).

## The five laws

1. **Expressions are data, never opaque thunks.** Everything can be inspected (`to_sexp`,
   `source_c`).
2. **The oracle is the semantics.** A backend is correct iff it is indistinguishable from the
   oracle; the differential battery is the judge.
3. **No compiler is written here.** Backends drive existing engines (system cc today; libgccjit /
   libtcc in-process next) through FFI and the toolchain.
4. **Always runnable.** The chain terminates at the oracle; a missing toolchain degrades speed,
   never behavior.
5. **Runtime knowledge is fuel.** Building kernels at runtime turns runtime constants into folded
   instructions — the one move AOT languages cannot make.

## Roadmap

- **libgccjit backend** — same GCC optimizer, in-process through FFI, no subprocess or temp files
- **libtcc backend** — instant in-process compilation for low-latency specialization
- GVL release on buffer-only kernels (true parallelism), `i64`/`f32` buffers, optional
  bounds-checked native mode, kernel fusion along composition edges
- berylx bridge: kernels as workflow task leaves (effect tree stays the linker)

## Development

```bash
bundle install
rake test    # unit + oracle semantics + differential battery (needs a C toolchain for the last)
rake bench   # numbers above
```

## License

MIT.
