# frozen_string_literal: true

require 'minitest/autorun'
require 'moissanite'

# extent guard — native は生ポインタを信じて走るので、要素数がバッファ長を
# 超えると黙ってヒープを壊す。検査できる形 (単純な要素ごとループ) については
# 走らせる前に ArgumentError にする。検査できない形では **何も主張しない**
# — 守れない約束をするより、沈黙のほうが正しい。
class SafetyTest < Minitest::Test
  def elementwise
    Moissanite.kernel(:elementwise, out: :f64_buf, xs: :f64_buf, n: :i64) do |k, out, xs, n|
      k.count(n) { |i| k.store(out, i, xs[i] * 2.0) }
      k.ret 0
    end
  end

  def test_simple_elementwise_shape_is_guarded
    kernel = elementwise
    guard = kernel.extent_guard

    refute_nil guard
    assert_equal 2, guard.count_index
    assert_equal [0, 1], guard.buffer_indices.sort
  end

  def test_count_beyond_buffer_raises_instead_of_corrupting_memory
    kernel = elementwise
    xs = Moissanite::Buffer.f64([1.0, 2.0, 3.0])
    out = Moissanite::Buffer.f64(3)

    error = assert_raises(ArgumentError) { kernel.call(out, xs, 4) }
    assert_match(/out of bounds/, error.message)
    assert_raises(ArgumentError) { kernel.interpret(out, xs, 4) }
  end

  def test_exact_and_short_counts_are_allowed
    kernel = elementwise
    xs = Moissanite::Buffer.f64([1.0, 2.0, 3.0])
    out = Moissanite::Buffer.f64(3)
    kernel.call(out, xs, 3)

    assert_equal [2.0, 4.0, 6.0], out.to_a

    out.fill(0.0)
    kernel.call(out, xs, 1)

    assert_equal [2.0, 0.0, 0.0], out.to_a
  end

  def test_non_positive_count_is_allowed
    kernel = elementwise
    xs = Moissanite::Buffer.f64([1.0])
    out = Moissanite::Buffer.f64(1)
    kernel.call(out, xs, 0)
    kernel.call(out, xs, -5)

    assert_equal [0.0], out.to_a
  end

  # 添字がループ変数そのものでない形は解析対象外。guard を主張しない
  # (偽の安全を与えない)。この種の kernel は開発中 interpret で検査する。
  def test_strided_index_is_not_claimed_safe
    strided = Moissanite.kernel(:strided, out: :f64_buf, xs: :f64_buf, n: :i64) do |k, out, xs, n|
      k.count(n) { |i| k.store(out, i, xs[i * 2]) }
      k.ret 0
    end

    assert_nil strided.extent_guard
  end

  def test_nested_loops_are_not_claimed_safe
    grid = Moissanite.kernel(:grid, out: :f64_buf, w: :i64, h: :i64) do |k, out, w, h|
      k.count(h) do |y|
        k.count(w) { |x| k.store(out, (y * w) + x, 1.0) }
      end
      k.ret 0
    end

    assert_nil grid.extent_guard
  end

  def test_scalar_only_kernel_has_no_guard
    scalar = Moissanite.kernel(:scalar, x: :f64) { |k, x| k.ret x * 2.0 }

    assert_nil scalar.extent_guard
  end

  def test_fused_pipeline_and_reduction_are_guarded
    pipe = Moissanite::Pipeline.f64.map { |v| v * 2.0 }
    xs = Moissanite::Buffer.f64([1.0, 2.0])
    out = Moissanite::Buffer.f64(2)

    assert_raises(ArgumentError) { pipe.fuse.call(out, xs, 3) }
    assert_raises(ArgumentError) { pipe.sum.call(xs, 3) }
    assert_in_delta 6.0, pipe.sum.call(xs, 2)
  end

  def test_dot_product_checks_every_input
    dot = Moissanite::Pipeline.f64(arity: 2).map { |a, b| a * b }.sum(:dot)
    long = Moissanite::Buffer.f64([1.0, 2.0, 3.0])
    short = Moissanite::Buffer.f64([1.0, 2.0])

    assert_raises(ArgumentError) { dot.call(long, short, 3) }
    assert_in_delta 5.0, dot.call(long, short, 2)
  end

  # view は親より短い窓なので、guard は窓の長さで判定しなければならない。
  def test_guard_uses_view_size_not_parent_size
    kernel = elementwise
    parent = Moissanite::Buffer.f64(10)
    window = parent.view(4, 2)
    out = Moissanite::Buffer.f64(2)

    assert_raises(ArgumentError) { kernel.call(out, window, 5) }
    kernel.call(out, window, 2)

    assert_equal [0.0, 0.0], out.to_a
  end
end
