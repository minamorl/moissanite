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

## Numbers (Ruby 3.3, gcc 13 `-O3`, rustc 1.94 `--release` + LTO, same algorithm, same run)

| workload                                         | moissanite                    | Rust (std, release)    |
| ------------------------------------------------ | ----------------------------- | ---------------------- |
| mandelbrot 600×400, limit 500, 1 thread          | **115 ms** (checksum equal)   | 114 ms                 |
| mandelbrot, 4 plain `Thread.new` + dynamic bands | **31 ms** (3.65× scaling)     | (needs rayon)          |
| horner deg-8, runtime coefficients               | **1.85 ns/el** (specialized)  | 3.51 ns/el (generic)   |
| 4-stage pipeline **composed at runtime**         | **1.8 ns/el** (fused, 1 pass) | 7.6 ns/el (dyn-chain)  |
| the same pipeline hardcoded at compile time      | —                             | 1.5 ns/el (hand-fused) |
| the same pipeline on 4 threads (`call_parallel`) | **0.80 ns/el**                | (needs rayon)          |
| 4-stage **map-reduce** composed at runtime       | **1.9 ns/el** (no buffer)     | 9.0 ns/el (dyn-chain)  |
| the same map-reduce as a compile-time iterator   | —                             | 2.2 ns/el (zero-cost)  |
| any of these on the pure-Ruby oracle             | ~90× slower                   | —                      |

Four honest readings (absolute times vary with machine load; compare within one run):

- **Parity at the floor.** A kernel written as Ruby data ties `rustc -O3` on a classic numeric
  loop, with an identical checksum — because it goes through the same class of optimizer.
- **Ahead where AOT cannot follow.** The horner kernel is _built at runtime_, so coefficients
  that only exist at runtime are folded into the instruction stream before `-O3` sees them.
  A stock AOT binary must stay generic. (Rust could match it only by shipping its own JIT.)
- **Dynamism is free here and expensive there.** Compare the two pipeline rows on the Rust side:
  the _same_ 4-stage chain costs 1.5 ns/el baked into the binary and 7.6 ns/el when assembled at
  runtime through `Box<dyn Fn>` — a **~5× tax on dynamism**, paid in indirect calls and lost
  fusion. moissanite composes at runtime and still fuses into one vectorized pass, so it runs
  **~4× faster than runtime-composed Rust** while staying within ~1.2× of the hardcoded build.
  That gap is the whole thesis in one table.
- **Fused map-reduce reaches zero-cost-abstraction speed.** Folding the reduction in too means no
  output buffer exists at all — input in, scalar out. Across runs moissanite lands at
  1.7–2.1 ns/el, on top of Rust's compile-time-fused iterator chain at 2.1–2.2 ns/el. Rust's
  headline zero-cost abstraction, matched by a pipeline that did not exist when the program
  started — and ~4.8× ahead of the same chain composed at runtime in Rust.
- **Parallel with plain threads.** `Fiddle` releases the GVL during native calls, so ordinary
  Ruby `Thread.new` scales native kernels across cores — 3.65× on 4 cores with a five-line
  dynamic work queue, bit-identical output. The Rust column would need rayon and a rebuild.

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

Buffers are raw memory shared by both levels — the oracle reads them bounds-checked,
native code receives the bare pointer:

```ruby
xs  = Moissanite::Buffer.f64([1.0, 2.0, 3.0])
out = Moissanite::Buffer.f64(3)
poly.call(out, xs, 3)
out.to_a
```

Integer buffers work the same way (`Moissanite::Buffer.i64`, parameter type `:i64_buf`) — for
histograms, masks, counts and index tables:

```ruby
hist = Moissanite.kernel(:hist, bins: :i64_buf, xs: :f64_buf, n: :i64, lo: :f64, width: :f64) do |k, bins, xs, n, lo, width|
  k.count(n) do |i|
    slot = k.let(((xs[i] - lo) / width).to_i64)   # f64 -> i64 is always explicit
    k.store(bins, slot, bins[slot] + 1)
  end
  k.ret 0
end
```

## Semantics (pinned by the oracle, enforced on backends by the differential battery)

| topic         | rule                                                                                                                                                                                                                                          |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| types         | scalars `:f64` (IEEE 754 double), `:i64` (64-bit two's complement), `:bool`; buffers `:f64_buf`, `:i64_buf` — both are 8 bytes wide, so a mismatched buffer would be a silent reinterpretation in native code and is rejected before the call |
| i64 overflow  | wraps (backends compile with `-fwrapv`)                                                                                                                                                                                                       |
| i64 `/` `%`   | truncate toward zero, remainder follows the dividend (C semantics, not Ruby's)                                                                                                                                                                |
| i64 `/ 0`     | oracle raises `MathError`; native is undefined — guard before dividing                                                                                                                                                                        |
| f64           | bit-exact with Ruby `Float` (`-ffp-contract=off`, hex-float constants)                                                                                                                                                                        |
| `&` `\|`      | bool-only, short-circuit in both levels                                                                                                                                                                                                       |
| casts         | `.to_f64`, `.to_i64` (truncates toward zero; out-of-range raises in the oracle)                                                                                                                                                               |
| mixed types   | never implicit — `f64 + i64` is a build-time `TypeMismatch`                                                                                                                                                                                   |
| `count(n)`    | `n` evaluated once at loop entry; `break_if` exits the innermost loop                                                                                                                                                                         |
| libm          | `.sqrt .sin .cos .exp .log .abs .min .max` (f64) — same libm as Ruby's `Math`, so bit-identical; negative `sqrt`/`log` give C's quiet `NaN`, `min`/`max` follow `fmin`/`fmax` NaN rules                                                       |
| buffer bounds | oracle checks every access (`IndexError`). For kernels with a simple elementwise shape both levels also reject an out-of-range count _before running_ (see below); other shapes are unchecked in native code                                  |
| falling off   | impossible — kernels must end in `k.ret`, validated at build                                                                                                                                                                                  |

### The extent guard

Native code takes bare pointers, so a count larger than the buffer would silently corrupt the
heap. That is a defect, not a missing feature, so moissanite closes it where it can prove the
condition. When a kernel's body is a single `count(n)` loop over an `:i64` parameter and every
buffer index is exactly that loop variable — the shape of every elementwise kernel and everything
`Pipeline` builds — the safe precondition is just `n ≤ buffer.size`, and both `call` and
`interpret` check it up front:

```ruby
kernel.call(out, xs, 4_000_000)
# ArgumentError: n=4000000 exceeds xs (3 elements) — the kernel would read or write out of bounds
```

For any other shape (strided indices, nested loops, computed offsets) `kernel.extent_guard`
returns `nil` and **nothing is claimed**. Silence beats a promise that cannot be kept; develop
those kernels against `interpret`, which bounds-checks every access.

## Backends

Selection is a fallback chain — **it works everywhere, and is fast where it can be**:

1. `cc` — emits C from the tree, compiles `-O3 -fwrapv -ffp-contract=off` with the system
   compiler, `dlopen`s the result, calls it through `Fiddle::Function`. Best code; ~70 ms cold
   compile round-trip.
2. `tcc` — the same emitted C through TinyCC when installed: **~11 ms compile+dlopen** (6× faster
   round-trip) at ~1.7× slower runtime. Force it with `MOISSANITE_BACKEND=tcc` when
   specialization latency beats peak speed — e.g. weaving a kernel per request.
3. `oracle` — always available.

Artifacts are content-addressed by SHA-256 of source + toolchain: the same tree never compiles
twice per toolchain. The differential battery verifies every available toolchain against the
oracle, so `cc` and `tcc` are held to identical semantics.

Environment knobs: `MOISSANITE_BACKEND=oracle|cc|tcc` (force), `MOISSANITE_CC` / `MOISSANITE_TCC`
(compilers), `MOISSANITE_CACHE_DIR` (artifact cache).

## Fusion: pipelines composed at runtime, executed as one pass

A `Pipeline` is a chain of elementwise stages. Each stage is an ordinary Ruby block taking an
expression and returning an expression, so composing stages is just function composition — and
because stages are _values_, the whole chain folds into a single loop body:

```ruby
gain = load_from_config          # only exists at runtime

pipe = Moissanite::Pipeline.f64
                           .map { |v| (v * 2.0) + 1.0 }
                           .map { |v| v.abs.sqrt }
                           .map { |v| (v * gain) - 0.25 }
                           .map { |v| v.min(3.0).max(-3.0) }

pipe.fuse.call(out, xs, n)       # one kernel, one pass over memory
```

`pipe.stage_kernels` gives the same math as one kernel per stage — N passes over memory, the shape
you get when you call a library function per stage. Fused is **3.0× faster** at 4M elements and
bit-identical (`test/pipeline_test.rb` pins that equality; the win is memory traffic, not math).

Folding a reduction in removes the output buffer entirely — the intermediate values never reach
memory at all:

```ruby
pipe.sum.call(xs, n)                                   # => Float, one pass, no allocation
pipe.reduce(0.0, :peak) { |acc, v| acc.max(v) }        # any (acc, value) -> Expr combiner
Moissanite::Pipeline.f64(arity: 2).map { |a, b| a * b }.sum.call(xs, ys, n)  # dot product
```

The accumulation is sequential in index order, so the oracle and every backend agree bit-for-bit
even in floating point. Fusing the reduce is **1.8× faster** than mapping into a buffer and
summing it.

This is where computation-as-data pays off structurally. A statically compiled language fuses when
the whole chain is visible at compile time (iterator chains, expression templates). When the chain
is assembled at runtime — from config, a query, a plugin list — it falls back to indirect calls and
separate passes. moissanite has the chain as data at exactly the moment it needs it.

Two implementation notes worth knowing, both found by reading the generated assembly:

- Each stage result is bound with `let`, so a stage that uses its input twice (`v * v`) does not
  duplicate the subtree. Trees stay linear in stage count.
- `min`/`max` are emitted as inlined helpers rather than libm `fmin`/`fmax`. gcc lowers `fmin` to a
  PLT call _per element_ and gives up on vectorizing the loop; inlining the identical NaN rules
  restored `sqrtpd` and made the fused pipeline **2.3× faster** with a bit-identical checksum.

## Parallelism

`Fiddle::Function` releases the GVL while the native code runs, so kernels scale across cores
with ordinary Ruby threads — no Ractors, no C threading, no unsafe. `Buffer#view(offset, size)`
gives zero-copy disjoint windows of one buffer, which makes concurrent writes safe by
construction (different threads touch different addresses).

For any kernel the extent guard recognizes, that split is already proven correct, so
`call_parallel` does it for you — same buffers, same result, bit-identical:

```ruby
kernel.call_parallel(out, xs, n, threads: 4)   # => per-band return values
```

**The safety analysis and the parallelism analysis are the same analysis.** "Every buffer index is
exactly the loop variable" is what makes `n ≤ size` sufficient for safety _and_ what makes index
ranges independent for parallelism — both are reading off the same property: element `i` of the
output depends only on element `i` of the input. So a kernel is parallel-ready the moment it is
provably in-bounds; nothing extra is declared. Kernels the guard cannot prove (nested loops,
strided indices) raise `BuildError` instead of racing.

Reductions come back as an array of per-band partials. Combining them is the caller's call — and
their sum is _not_ bit-identical to the serial run, because floating-point addition is not
associative and the association order changed.

To split by hand — for kernels the guard does not cover, like the 2-D mandelbrot grid — the same
two rules apply:

```ruby
queue = Queue.new
bands.times { |s| queue << s }
threads = 4.times.map do
  Thread.new do
    while (s = queue.pop(true) rescue nil)
      window = out.view(s * band_rows * w, band_rows * w)
      mandel.call(window, w, band_rows, s * band_rows, x0, y0, dx, dy, limit)
    end
  end
end
threads.each(&:join)
```

Two rules make parallel decomposition exact:

- **Slice with index offsets, not coordinate offsets.** Pass `y_off: :i64` and compute
  `(y + y_off) * dy` inside the kernel; pre-adding `y0 + slice * rows * dy` outside changes
  floating-point rounding and the slices stop being bit-identical to the whole run
  (`test/parallel_test.rb` pins the bit-identical decomposition).
- **Balance with a queue.** Workloads like mandelbrot are row-skewed; a five-line dynamic band
  queue restores near-linear scaling where static blocks stall.

## The five laws

1. **Expressions are data, never opaque thunks.** Everything can be inspected (`to_sexp`,
   `source_c`).
2. **The oracle is the semantics.** A backend is correct iff it is indistinguishable from the
   oracle; the differential battery is the judge.
3. **No compiler is written here.** Backends drive existing engines (system cc and tcc today;
   in-process libgccjit next) through FFI and the toolchain.
4. **Always runnable.** The chain terminates at the oracle; a missing toolchain degrades speed,
   never behavior.
5. **Runtime knowledge is fuel.** Building kernels at runtime turns runtime constants into folded
   instructions — the one move AOT languages cannot make.

## Roadmap

- **libgccjit / libtcc in-process backends** — same engines without subprocess or temp files
- `i64`/`f32` buffers, reductions and `zip` in `Pipeline`, optional bounds-checked native mode
- berylx bridge: kernels as workflow task leaves (effect tree stays the linker)

## Development

```bash
bundle install
rake test    # unit + oracle semantics + differential battery (needs a C toolchain for the last)
rake bench   # numbers above
```

## License

MIT.
