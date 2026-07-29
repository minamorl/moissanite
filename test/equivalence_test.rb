# frozen_string_literal: true

require 'minitest/autorun'
require 'moissanite'

# 差分検証 — moissanite の道徳的中心。
#
# oracle (純 Ruby) が意味論の正典であり、native backend の正しさの定義は
# 「oracle と同じ値を返すこと」以外に存在しない。構造化カーネル一式と、
# シード固定のランダム式バッテリーの両方で oracle vs cc を突き合わせる。
class EquivalenceTest < Minitest::Test
  def setup
    skip 'no working native toolchain: backends untestable' if native_backends.empty?
  end

  # 使える toolchain backend 全部 (cc / tcc) を oracle に対して検証する。
  def native_backends
    [Moissanite::Backend::Cc, Moissanite::Backend::Tcc].select(&:available?)
  end

  # f64 は NaN 同士を除きビット一致を要求する。
  def assert_same_value(oracle, native, context)
    if oracle.is_a?(Float) && oracle.nan?
      assert_predicate native, :nan?, context
    else
      assert_equal oracle, native, context
    end
  end

  def assert_kernel_equivalent(kernel, arg_tuples)
    native_backends.each do |backend|
      compiled = backend.compile(kernel)

      arg_tuples.each do |args|
        assert_same_value kernel.interpret(*args), compiled.call(*args),
                          "#{backend.tag}: #{kernel.name}(#{args.inspect})"
      end
    end
  end

  def test_mandelbrot_point
    kernel = Moissanite.kernel(:mandel, cr: :f64, ci: :f64, limit: :i64) do |k, cr, ci, limit|
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
      k.ret n
    end

    points = [[0.0, 0.0], [2.0, 2.0], [-0.75, 0.1], [0.285, 0.01], [-1.401155, 0.0]]

    assert_kernel_equivalent(kernel, points.map { |cr, ci| [cr, ci, 500] })
  end

  def test_i64_wrap_div_mod
    kernel = Moissanite.kernel(:wrapmix, a: :i64, b: :i64) do |k, a, b|
      prod = k.let(a * b)
      k.ret_if b.eq(0), prod
      k.ret ((prod + (a / b)) % 1000) + (a % b)
    end

    tuples = [[2**62, 3], [-7, 2], [7, -2], [-9, -4], [(2**63) - 1, 1], [123, 0]]

    assert_kernel_equivalent kernel, tuples
  end

  def test_buffer_store_load_roundtrip
    kernel = Moissanite.kernel(:stencil, out: :f64_buf, xs: :f64_buf, n: :i64) do |k, out, xs, n|
      k.count(n) do |i|
        left = k.select(i.eq(0), 0.0, xs[k.select(i.eq(0), 0, i - 1)])
        k.store(out, i, (left + xs[i]) * 0.5)
      end
      k.ret 0
    end

    xs = Moissanite::Buffer.f64([1.0, 2.0, 4.0, 8.0])
    out_oracle = Moissanite::Buffer.f64(4)
    kernel.interpret(out_oracle, xs, 4)
    native_backends.each do |backend|
      out_native = Moissanite::Buffer.f64(4)
      backend.compile(kernel).call(out_native, xs, 4)

      assert_equal out_oracle.to_a, out_native.to_a, backend.tag.to_s
    end
  end

  # バイト列上の状態機械 — u8 バッファ本来の用途 (プロトコル解析)。
  # native では uint8_t が C の整数昇格で int になるので、式言語が :i64 と
  # 言っている型と食い違わないことをここで縛る。oracle の正しさ自体は
  # Ruby の String#index を第三の証人にして確かめる。
  def test_u8_scanner_matches_oracle
    kernel = Moissanite.kernel(:find_crlf, buf: :u8_buf, n: :i64) do |k, buf, n|
      found = k.let(-1)
      k.count(n - 1) do |i|
        k.if_(buf[i].eq(13) & buf[i + 1].eq(10)) do
          k.assign(found, i)
          k.break_if(true)
        end
      end
      k.ret found
    end

    ["GET / HTTP/1.1\r\nHost: x\r\n\r\n", 'no line ending here', "\r\n", "a\rb\nc\r\n", 'x'].each do |request|
      buf = Moissanite::Buffer.bytes(request)

      assert_kernel_equivalent kernel, [[buf, buf.size]]
      assert_equal(request.index("\r\n") || -1, kernel.interpret(buf, buf.size), request.inspect)
    end
  end

  # u8 の読み出しは必ず int64_t へ広げてから使う。バイト 4 つの積は
  # 255^4 = 4_228_250_625 で int を溢れるので、広げないと native は符号付き
  # int の overflow (未定義動作) になり oracle と食い違う。式言語が :i64 と
  # 言っている以上 64bit で計算されなければならない、という約束の証拠。
  def test_u8_loads_are_widened_before_arithmetic
    kernel = Moissanite.kernel(:quad, buf: :u8_buf, n: :i64) do |k, buf, _n|
      k.ret buf[0] * buf[1] * buf[2] * buf[3]
    end

    buf = Moissanite::Buffer.u8([255, 255, 255, 255])

    assert_equal 4_228_250_625, kernel.interpret(buf, 4)
    assert_kernel_equivalent kernel, [[buf, 4]]
  end

  # u8 への書き込みの切り詰め: oracle は value & 0xFF、native は (uint8_t)
  # キャスト。両者が同じでなければ「バイトを書く」カーネルは書けない。
  def test_u8_store_truncation_matches_oracle
    kernel = Moissanite.kernel(:scale, out: :u8_buf, src: :u8_buf, n: :i64, factor: :i64) do |k, out, src, n, factor|
      k.count(n) { |i| k.store(out, i, src[i] * factor) }
      k.ret 0
    end

    src = Moissanite::Buffer.u8([1, 100, 200, 255])
    out_oracle = Moissanite::Buffer.u8(4)
    kernel.interpret(out_oracle, src, 4, 3)

    assert_equal [3, 44, 88, 253], out_oracle.to_a
    native_backends.each do |backend|
      out_native = Moissanite::Buffer.u8(4)
      backend.compile(kernel).call(out_native, src, 4, 3)

      assert_equal out_oracle.to_a, out_native.to_a, backend.tag.to_s
    end
  end

  def test_control_flow_mix
    kernel = Moissanite.kernel(:ctrl, x: :f64, n: :i64) do |k, x, n|
      acc = k.let(0.0)
      k.count(n) do |i|
        k.if_else(
          (i % 2).eq(0),
          -> { k.assign(acc, acc + x) },
          -> { k.assign(acc, acc - (x * 0.5)) }
        )
        k.ret_if acc > 100.0, acc
      end
      k.ret acc
    end

    assert_kernel_equivalent kernel, [[1.5, 10], [50.0, 10], [-3.25, 7], [0.1, 1000]]
  end

  def test_specialized_polynomial_matches
    coeffs = [1.25, -0.5, 3.0, 0.125, -2.0]
    kernel = Moissanite.kernel(:poly, out: :f64_buf, xs: :f64_buf, n: :i64) do |k, out, xs, n|
      k.count(n) do |i|
        x = k.let(xs[i])
        acc = k.let(coeffs.first)
        coeffs.drop(1).each { |c| k.assign(acc, (acc * x) + c) }
        k.store(out, i, acc)
      end
      k.ret 0
    end

    xs = Moissanite::Buffer.f64([-2.0, -0.5, 0.0, 0.3, 1.7])
    a = Moissanite::Buffer.f64(5)
    kernel.interpret(a, xs, 5)
    native_backends.each do |backend|
      b = Moissanite::Buffer.f64(5)
      backend.compile(kernel).call(b, xs, 5)

      assert_equal a.to_a, b.to_a, backend.tag.to_s
    end
  end

  # 整数バッファ + 計算された添字 (extent guard の対象外の形) でも、
  # oracle と native は一致しなければならない。
  def test_histogram_with_i64_buffer_matches_oracle
    kernel = Moissanite.kernel(:hist, bins: :i64_buf, xs: :f64_buf, n: :i64,
                                      nbins: :i64, lo: :f64, width: :f64) do |k, bins, xs, n, nbins, lo, width|
      k.count(n) do |i|
        raw = k.let(((xs[i] - lo) / width).to_i64)
        slot = k.let(k.select(raw < 0, 0, k.select(raw >= nbins, nbins - 1, raw)))
        k.store(bins, slot, bins[slot] + 1)
      end
      k.ret 0
    end

    xs = Moissanite::Buffer.f64([0.0, 0.5, 1.5, 2.5, 9.9, -3.0, 100.0, 4.999])
    oracle_bins = Moissanite::Buffer.i64(4).fill(0)
    kernel.interpret(oracle_bins, xs, 8, 4, 0.0, 2.5)

    native_backends.each do |backend|
      bins = Moissanite::Buffer.i64(4).fill(0)
      backend.compile(kernel).call(bins, xs, 8, 4, 0.0, 2.5)

      assert_equal oracle_bins.to_a, bins.to_a, backend.tag.to_s
    end
  end

  def test_math_functions_match_libm
    kernel = Moissanite.kernel(:mathmix, x: :f64, y: :f64) do |k, x, y|
      a = k.let(x.abs.sqrt + y.sin + x.cos)
      b = k.let((x.exp.min(1e10) + (y.abs + 1.0e-9).log).max(a))
      k.ret k.select(x > y, a.min(b), a.max(b)) + x.sqrt
    end

    tuples = [[0.5, -1.25], [-2.0, 3.0], [4.0, 0.0], [-0.75, -0.1], [9.0, 2.5]]

    assert_kernel_equivalent kernel, tuples
  end

  # シード固定のランダム式バッテリー: 定義済み意味論の範囲で式木を生成し、
  # oracle と native の一致を数値で殴って確かめる。
  def test_random_expression_battery
    rng = Random.new(42)
    30.times do |case_index|
      kernel = Moissanite.kernel(:"rand#{case_index}", a: :f64, b: :f64, m: :i64, n: :i64) do |k, *params|
        gen = RandomExpr.new(rng, params)
        k.ret gen.f64(3)
      end
      inputs = Array.new(6) { [rng.rand(-2.0..2.0), rng.rand(-2.0..2.0), rng.rand(-1000..1000), rng.rand(-1000..1000)] }

      assert_kernel_equivalent kernel, inputs
    end
  end

  # 意味論が定義済みの演算だけで式木を作る生成器 (0 除算・範囲外 cast は
  # 生成しない — それらは未定義でなく「oracle が raise する」領域で、
  # oracle_test が固定している)。
  class RandomExpr
    def initialize(rng, params)
      @rng = rng
      @a, @b, @m, @n = params
    end

    def f64(depth)
      if depth.zero?
        return @rng.rand(3) == 0 ? Moissanite::Expr.lift(@rng.rand(-2.0..2.0),
                                                         :f64) : [@a, @b].sample(random: @rng)
      end

      case @rng.rand(10)
      when 0 then f64(depth - 1) + f64(depth - 1)
      when 1 then f64(depth - 1) - f64(depth - 1)
      when 2 then f64(depth - 1) * f64(depth - 1)
      when 3 then f64(depth - 1) / f64(depth - 1)
      when 4 then i64(depth - 1).to_f64
      when 5 then Moissanite::Expr.select(bool(depth - 1), f64(depth - 1), f64(depth - 1))
      when 6 then f64(depth - 1).abs.sqrt
      when 7 then f64(depth - 1).sin
      when 8 then f64(depth - 1).min(f64(depth - 1))
      when 9 then -f64(depth - 1)
      end
    end

    def i64(depth)
      if depth.zero?
        return @rng.rand(3) == 0 ? Moissanite::Expr.lift(@rng.rand(-50..50),
                                                         :i64) : [@m, @n].sample(random: @rng)
      end

      case @rng.rand(6)
      when 0 then i64(depth - 1) + i64(depth - 1)
      when 1 then i64(depth - 1) - i64(depth - 1)
      when 2 then i64(depth - 1) * i64(depth - 1)
      when 3 then i64(depth - 1) / Moissanite::Expr.lift(@rng.rand(1..9), :i64)
      when 4 then Moissanite::Expr.select(bool(depth - 1), i64(depth - 1), i64(depth - 1))
      when 5 then -i64(depth - 1)
      end
    end

    def bool(depth)
      base = @rng.rand(2).zero? ? f64(depth) > f64(depth) : i64(depth) <= i64(depth)
      case @rng.rand(4)
      when 0 then base & bool_leaf
      when 1 then base | bool_leaf
      when 2 then base.not
      else base
      end
    end

    def bool_leaf
      @rng.rand(2).zero? ? (@a > 0.0) : @m.ne(0)
    end
  end
end
