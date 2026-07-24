# frozen_string_literal: true

# moissanite ベンチマーク — 3 つの問いに数字で答える:
#   1. mandelbrot:  cc backend は最適化 C の速度そのものか (oracle 比も測る)
#   2. horner:      実行時特殊化 (定数畳み込み済みカーネル) は generic 実装
#                   よりどれだけ速いか — AOT 言語が持てない利得の測定
#   3. saxpy:       FFI 境界の固定費は要素数何個で償却されるか
#
# Rust 対抗 (同アルゴリズム・std のみ・release+LTO) は bench/rust_baseline:
#   cd bench/rust_baseline && cargo build --release
#   ./target/release/moissanite_rust_baseline
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'etc'
require 'moissanite'

def measure(iters, &)
  yield
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iters.times(&)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) / iters
end

def row(label, seconds, work = nil)
  per = work ? format('  %8.2f ns/elem', seconds * 1e9 / work) : ''
  puts format('%-44s %10.2f ms%s', label, seconds * 1e3, per)
end

puts "moissanite #{Moissanite::VERSION}  ruby #{RUBY_VERSION}  cc=#{Moissanite::Backend::Cc.available?}"
puts

# ---------------------------------------------------------------- mandelbrot
W = 600
H = 400
LIMIT = 500

# 行オフセット (y_off) で分割可能な形。座標前送りでなくオフセット渡しに
# するのは、浮動小数の非結合性で分割結果の ci が ulp ずれないようにするため
# (これで並列分割は全体実行と構造的にビット一致する)。
mandel = Moissanite.kernel(:mandel_grid, out: :f64_buf, w: :i64, h: :i64, y_off: :i64, x0: :f64,
                                         y0: :f64, dx: :f64, dy: :f64,
                                         limit: :i64) do |k, out, w, h, y_off, x0, y0, dx, dy, limit|
  k.count(h) do |y|
    k.count(w) do |x|
      cr = k.let(x0 + (x.to_f64 * dx))
      ci = k.let(y0 + ((y + y_off).to_f64 * dy))
      zr = k.let(0.0)
      zi = k.let(0.0)
      n = k.let(0)
      k.count(limit) do |i|
        t = k.let((zr * zr) - (zi * zi) + cr)
        k.assign(zi, (2.0 * zr * zi) + ci)
        k.assign(zr, t)
        k.break_if((zr * zr) + (zi * zi) > 4.0)
        k.assign(n, i + 1)
      end
      k.store(out, (y * w) + x, n.to_f64)
    end
  end
  k.ret 0
end

out = Moissanite::Buffer.f64(W * H)
args = [out, W, H, 0, -2.5, -1.0, 3.5 / W, 2.0 / H, LIMIT]
native = measure(3) { mandel.call(*args) }
checksum = out.sum
row "mandelbrot #{W}x#{H} limit=#{LIMIT}  [cc]", native
tiny = [out, W, 4, 0, -2.5, -1.0, 3.5 / W, 2.0 / H, LIMIT] # oracle は 1/100 の行数で測って外挿
oracle = measure(1) { mandel.interpret(*tiny) } * (H / 4.0)
row 'mandelbrot (oracle, 外挿)', oracle
puts format('  checksum=%.1f  oracle/cc = %.0fx', checksum, oracle / native)
puts

# ---------------------------------------------------------------- 並列: GVL 解放の実証
# Fiddle::Function 呼び出し中は GVL が解放されるので、素の Thread.new と
# 互いに素な Buffer#view だけで全コアが回る (分割のビット一致は
# test/parallel_test.rb が固定)。mandelbrot は行ごとに計算量が偏るので、
# 行バンドを Queue で配る動的スケジューリング (素の Ruby 5 行) で均す —
# Rust なら rayon を持ち出す所が、ここではただのコードになる。
dy = 2.0 / H
band_rows = 25
bands = H / band_rows
[2, 4].each do |threads|
  next if threads > Etc.nprocessors

  sliced = Moissanite::Buffer.f64(W * H)
  sec = measure(3) do
    queue = Queue.new
    bands.times { |s| queue << s }
    threads.times.map do
      Thread.new do
        while (s = begin
          queue.pop(true)
        rescue StandardError
          nil
        end)
          window = sliced.view(s * band_rows * W, band_rows * W)
          mandel.call(window, W, band_rows, s * band_rows, -2.5, -1.0, 3.5 / W, dy, LIMIT)
        end
      end
    end.each(&:join)
  end
  row "mandelbrot #{threads} threads (dynamic bands)", sec
  puts format('  scaling = %.2fx  identical = %s', native / sec, sliced.sum == checksum)
end
puts

# ---------------------------------------------------------------- horner: 実行時特殊化
N = 2_000_000
DEGREE = 8
rng = Random.new(7)
coeffs = Array.new(DEGREE + 1) { rng.rand(-1.0..1.0) } # 実行時にしか判らない係数

# (a) 特殊化: 係数を定数として畳み込んだカーネルを「いま」組む。
#     Ruby の each がカーネルを編む — メタプログラミングが特殊化器になる。
poly_spec = Moissanite.kernel(:poly_spec, out: :f64_buf, xs: :f64_buf, n: :i64) do |k, out, xs, n|
  k.count(n) do |i|
    x = k.let(xs[i])
    acc = k.let(coeffs.first)
    coeffs.drop(1).each { |c| k.assign(acc, (acc * x) + c) }
    k.store(out, i, acc)
  end
  k.ret 0
end

# (b) generic: 係数をバッファで受け、内側ループで畳む (AOT 的な一般形)。
poly_gen = Moissanite.kernel(:poly_gen, out: :f64_buf, xs: :f64_buf, cs: :f64_buf,
                                        n: :i64, m: :i64) do |k, out, xs, cs, n, m|
  k.count(n) do |i|
    x = k.let(xs[i])
    acc = k.let(cs[0])
    k.count(m - 1) do |j|
      k.assign(acc, (acc * x) + cs[j + 1])
    end
    k.store(out, i, acc)
  end
  k.ret 0
end

xs = Moissanite::Buffer.f64(Array.new(N) { rng.rand(-1.5..1.5) })
cs = Moissanite::Buffer.f64(coeffs)
out_s = Moissanite::Buffer.f64(N)
out_g = Moissanite::Buffer.f64(N)

spec = measure(5) { poly_spec.call(out_s, xs, N) }
gen  = measure(5) { poly_gen.call(out_g, xs, cs, N, DEGREE + 1) }
row "horner deg=#{DEGREE} n=#{N}  [特殊化 cc]", spec, N
row "horner deg=#{DEGREE} n=#{N}  [generic cc]", gen, N
raise 'spec/gen mismatch' unless out_s.to_a.first(100) == out_g.to_a.first(100)

puts format('  checksum=%.6f  特殊化の利得 = %.2fx', out_s.sum, gen / spec)
puts '  (Rust 対抗値は bench/rust_baseline の horner 行と比較する — 係数は同じ乱数列)'
puts "  coeffs: #{coeffs.map { |c| format('%.17g', c) }.join(' ')}"
puts

# ---------------------------------------------------------------- saxpy: FFI 境界の償却
saxpy = Moissanite.kernel(:saxpy, out: :f64_buf, xs: :f64_buf, n: :i64, a: :f64) do |k, out, xs, n, a|
  k.count(n) do |i|
    k.store(out, i, (a * xs[i]) + xs[i])
  end
  k.ret 0
end

[100, 1_000, 10_000, 100_000, 1_000_000].each do |n|
  x = Moissanite::Buffer.f64(Array.new(n) { rng.rand })
  o = Moissanite::Buffer.f64(n)
  iters = (10_000_000 / n).clamp(20, 5000)
  sec = measure(iters) { saxpy.call(o, x, n, 2.0) }
  row "saxpy n=#{n}  [cc]", sec, n
end
puts '  (小さい n の ns/elem 上昇分が FFI 境界の固定費)'
puts

# ---------------------------------------------------------------- Rust 対抗を同じ係数で起動
rust_bin = File.expand_path('rust_baseline/target/release/moissanite_rust_baseline', __dir__)
if File.executable?(rust_bin)
  puts '--- rust baseline (同係数) ---'
  system(rust_bin, *coeffs.map(&:to_s))
else
  puts '(rust baseline 未ビルド: cd bench/rust_baseline && cargo build --release して再実行すると対抗値が並ぶ)'
end
