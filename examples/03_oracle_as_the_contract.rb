# frozen_string_literal: true

# oracle を「正しさの契約」として使う開発の流れ。
#
# moissanite に「native が正しいことの証明」は無い。あるのは
# 「native は oracle と区別がつかない」という *測れる* 主張だけで、
# それはライブラリの内部だけでなく、あなたのカーネルにも同じ形で使える。
#
#   ruby examples/03_oracle_as_the_contract.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'moissanite'

# 移動平均に似た、境界の扱いが厄介になりがちなカーネル。
# 添字がループ変数そのものではないので extent guard は **何も主張しない** —
# つまり native では境界を守るのは呼び手の責任になる。だからこそ oracle で
# 検査しながら書く。
smooth = Moissanite.kernel(:smooth, out: :f64_buf, xs: :f64_buf, n: :i64) do |k, out, xs, n|
  k.count(n) do |i|
    left = k.let(k.select(i.eq(0), xs[0], xs[k.select(i.eq(0), 0, i - 1)]))
    right = k.let(k.select(i.eq(n - 1), xs[n - 1], xs[k.select(i.eq(n - 1), n - 1, i + 1)]))
    k.store(out, i, (left + xs[i] + right) / 3.0)
  end
  k.ret 0
end

puts "extent guard: #{smooth.extent_guard.inspect}  (nil = この形は安全を主張しない)"
puts

# --- 1. 小さな入力で oracle と native を突き合わせる (開発時の習慣) ---
def compare(kernel, size, values)
  xs = Moissanite::Buffer.f64(values)
  native = Moissanite::Buffer.f64(size)
  oracle = Moissanite::Buffer.f64(size)
  kernel.call(native, xs, size)
  kernel.interpret(oracle, xs, size)
  [oracle.to_a == native.to_a, native.to_a]
end

cases = {
  '3 要素' => [1.0, 2.0, 3.0],
  '1 要素 (両端が同じ)' => [42.0],
  '負値と 0' => [-1.0, 0.0, 1.0, -2.0],
  '大きな値' => [1e15, -1e15, 1e15]
}

cases.each do |label, values|
  ok, result = compare(smooth, values.size, values)
  puts format('%-22s %s  %s', label, ok ? '一致' : '不一致!', result.map { |v| format('%.4g', v) }.join(' '))
  raise "oracle と native が食い違った: #{label}" unless ok
end
puts

# --- 2. 境界を踏み越える呼び出しは oracle が必ず捕まえる ---
# native は生ポインタで走るので、この検査は開発時にしか掛けられない。
xs = Moissanite::Buffer.f64([1.0, 2.0])
out = Moissanite::Buffer.f64(2)
begin
  smooth.interpret(out, xs, 5)
  puts 'oracle が境界超過を見逃した (ありえない)'
rescue IndexError => e
  puts "oracle が境界超過を検出: #{e.message}"
end
puts

# --- 3. 単純な形なら、その検査は本番経路にも常時掛かる ---
elementwise = Moissanite.kernel(:double_it, out: :f64_buf, xs: :f64_buf, n: :i64) do |k, out, xs, n|
  k.count(n) { |i| k.store(out, i, xs[i] * 2.0) }
  k.ret 0
end
puts "extent guard: #{elementwise.extent_guard.inspect}"
begin
  elementwise.call(out, xs, 5)
rescue ArgumentError => e
  puts "native 呼び出し前に停止: #{e.message}"
end
puts
puts '掟: 証明できる形は常時守る。できない形は黙る代わりに oracle で開発する。'
