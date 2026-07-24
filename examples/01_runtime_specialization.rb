# frozen_string_literal: true

# 実行時特殊化 — AOT 言語が構造的にできない一手。
#
# 「設定ファイルから読んだ係数」は、コンパイル済みバイナリにとっては
# 最後まで変数のままである。moissanite はカーネルを *実行時に組む* ので、
# その値を定数として命令列へ畳み込んでから -O3 に渡せる。
#
#   ruby examples/01_runtime_specialization.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'moissanite'

# --- 実行時にしか判らない設定 (本来は YAML なり DB なりから来る) ---
config = { 'coefficients' => [0.75, -1.5, 0.25, 2.0, -0.5], 'clip' => 8.0 }

coefficients = config.fetch('coefficients')
clip = config.fetch('clip')

# --- (a) 特殊化: 係数を定数として畳み込んだカーネルを「いま」組む ---
# Ruby の each が実行されるのはカーネルを *編む* ときだけで、
# 出来上がった C にはループも配列参照も残らない (source_c で確認できる)。
specialized = Moissanite.kernel(:specialized, out: :f64_buf, xs: :f64_buf, n: :i64) do |k, out, xs, n|
  k.count(n) do |i|
    x = k.let(xs[i])
    acc = k.let(coefficients.first)
    coefficients.drop(1).each { |c| k.assign(acc, (acc * x) + c) }
    k.store(out, i, acc.min(clip).max(-clip))
  end
  k.ret 0
end

# --- (b) 一般形: 係数をバッファで受け、内側ループで畳む (AOT 的な形) ---
generic = Moissanite.kernel(:generic, out: :f64_buf, xs: :f64_buf, cs: :f64_buf,
                                      n: :i64, degree: :i64, clip: :f64) do |k, out, xs, cs, n, degree, clip_v|
  k.count(n) do |i|
    x = k.let(xs[i])
    acc = k.let(cs[0])
    k.count(degree) { |j| k.assign(acc, (acc * x) + cs[j + 1]) }
    k.store(out, i, acc.min(clip_v).max(-clip_v))
  end
  k.ret 0
end

puts '--- 特殊化されたカーネルが発行する C (係数もクリップ幅も定数になっている) ---'
puts specialized.source_c

n = 2_000_000
rng = Random.new(1)
xs = Moissanite::Buffer.f64(Array.new(n) { rng.rand(-2.0..2.0) })
cs = Moissanite::Buffer.f64(coefficients)
a = Moissanite::Buffer.f64(n)
b = Moissanite::Buffer.f64(n)

def measure(iters, &)
  yield
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iters.times(&)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) / iters
end

fast = measure(5) { specialized.call(a, xs, n) }
slow = measure(5) { generic.call(b, xs, cs, n, coefficients.size - 1, clip) }

raise 'specialized and generic disagree' unless a.to_a == b.to_a

puts format('特殊化: %6.2f ms (%.2f ns/elem)', fast * 1e3, fast * 1e9 / n)
puts format('一般形: %6.2f ms (%.2f ns/elem)', slow * 1e3, slow * 1e9 / n)
puts format('利得  : %.2fx  (結果はビット一致)', slow / fast)
puts
puts '設定が変わればカーネルを組み直すだけ — 再ビルドも再デプロイも要らない。'
