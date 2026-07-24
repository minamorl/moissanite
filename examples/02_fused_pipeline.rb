# frozen_string_literal: true

# 実行時に組んだパイプラインを 1 パスへ融合し、全コアで走らせる。
#
# 段の並びが設定で決まる (= バイナリに焼けない) のに、融合もベクトル化も
# 並列化も効く。段が「値」だから実行の直前に畳めるという一点に尽きる。
#
#   ruby examples/02_fused_pipeline.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'etc'
require 'moissanite'

# --- 実行時に決まるパイプライン定義 (設定・クエリ・プラグイン列に相当) ---
recipe = [
  { op: 'scale', by: 2.5 },
  { op: 'offset', by: -1.0 },
  { op: 'magnitude' },
  { op: 'clip', at: 3.0 }
]

pipeline = recipe.reduce(Moissanite::Pipeline.f64) do |pipe, step|
  case step[:op]
  when 'scale' then pipe.map { |v| v * step[:by] }
  when 'offset' then pipe.map { |v| v + step[:by] }
  when 'magnitude' then pipe.map { |v| v.abs.sqrt }
  when 'clip' then pipe.map { |v| v.min(step[:at]).max(-step[:at]) }
  else raise ArgumentError, "unknown op #{step[:op]}"
  end
end

fused = pipeline.fuse(:recipe)
puts "--- #{pipeline.size} 段が 1 つのループ本体に畳まれている ---"
puts fused.source_c

n = 4_000_000
rng = Random.new(2)
xs = Moissanite::Buffer.f64(Array.new(n) { rng.rand(-5.0..5.0) })
one_pass = Moissanite::Buffer.f64(n)
staged = Moissanite::Buffer.f64(n)
parallel = Moissanite::Buffer.f64(n)
scratch = Moissanite::Buffer.f64(n)

def measure(iters, &)
  yield
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iters.times(&)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) / iters
end

fused_sec = measure(5) { fused.call(one_pass, xs, n) }

# 段ごとに独立カーネル = 段数だけメモリを往復する (ライブラリ関数を順に呼ぶ形)
stages = pipeline.stage_kernels
staged_sec = measure(5) do
  front = scratch
  back = staged
  stages.each_with_index do |kernel, index|
    kernel.call(back, index.zero? ? xs : front, n)
    front, back = back, front
  end
end
staged_result = stages.size.even? ? scratch : staged

threads = [Etc.nprocessors, 4].min
par_sec = measure(5) { fused.call_parallel(parallel, xs, n, threads: threads) }

puts format('段別 %d パス      : %6.2f ms (%.2f ns/elem)', stages.size, staged_sec * 1e3, staged_sec * 1e9 / n)
puts format('融合 1 パス       : %6.2f ms (%.2f ns/elem)  %.2fx', fused_sec * 1e3, fused_sec * 1e9 / n,
            staged_sec / fused_sec)
puts format('融合 x %d threads : %6.2f ms (%.2f ns/elem)  %.2fx', threads, par_sec * 1e3, par_sec * 1e9 / n,
            fused_sec / par_sec)
puts

raise 'fused vs staged mismatch' unless one_pass.to_a == staged_result.to_a
raise 'parallel mismatch' unless one_pass.to_a == parallel.to_a

puts '3 通りとも結果はビット一致 — 融合も並列化もメモリの触り方を変えただけで、数学は同じ。'
puts
puts "総和 (中間バッファ無しの融合 map-reduce): #{format('%.6f', pipeline.sum(:recipe_sum).call(xs, n))}"
