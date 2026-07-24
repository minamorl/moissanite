# frozen_string_literal: true

require 'minitest/autorun'
require 'moissanite'

# oracle (意味論の正典) の決め事のテスト。native との一致は
# equivalence_test が担い、ここは意味論そのものを固定する。
class OracleTest < Minitest::Test
  I64_MIN = -(2**63)
  I64_MAX = (2**63) - 1

  def scalar(ret_expr_builder, **params)
    Moissanite.kernel(:t, **params) do |k, *args|
      k.ret ret_expr_builder.call(k, *args)
    end
  end

  def test_i64_wraps_on_overflow
    k = scalar(->(_k, a, b) { a + b }, a: :i64, b: :i64)

    assert_equal I64_MIN, k.interpret(I64_MAX, 1)
    assert_equal I64_MAX, k.interpret(I64_MIN, -1)

    m = scalar(->(_k, a, b) { a * b }, a: :i64, b: :i64)

    assert_equal 0, m.interpret(2**32, 2**32)
  end

  def test_i64_division_truncates_toward_zero
    k = scalar(->(_k, a, b) { a / b }, a: :i64, b: :i64)

    assert_equal(-3, k.interpret(-7, 2))
    assert_equal(-3, k.interpret(7, -2))
    assert_equal(3, k.interpret(-7, -2))
  end

  def test_i64_modulo_follows_dividend_sign
    k = scalar(->(_k, a, b) { a % b }, a: :i64, b: :i64)

    assert_equal(-1, k.interpret(-7, 2))
    assert_equal(1, k.interpret(7, -2))
  end

  def test_i64_division_by_zero_raises
    k = scalar(->(_k, a, b) { a / b }, a: :i64, b: :i64)

    assert_raises(Moissanite::MathError) { k.interpret(1, 0) }
  end

  def test_f64_division_by_zero_is_ieee
    k = scalar(->(_k, a, b) { a / b }, a: :f64, b: :f64)

    assert_predicate k.interpret(1.0, 0.0), :infinite?
    assert_predicate k.interpret(0.0, 0.0), :nan?
  end

  def test_bool_and_short_circuits_past_division_by_zero
    k = Moissanite.kernel(:guarded, a: :i64, b: :i64) do |k2, a, b|
      k2.ret k2.select(b.ne(0) & ((a / b) > 10), 1, 0)
    end

    assert_equal 0, k.interpret(100, 0) # 短絡しなければ MathError になる
    assert_equal 1, k.interpret(100, 5)
  end

  def test_cast_truncates_toward_zero
    k = scalar(->(_k, x) { x.to_i64 }, x: :f64)

    assert_equal 2, k.interpret(2.9)
    assert_equal(-2, k.interpret(-2.9))
  end

  def test_cast_out_of_range_raises_in_oracle
    k = scalar(->(_k, x) { x.to_i64 }, x: :f64)

    assert_raises(Moissanite::MathError) { k.interpret(Float::NAN) }
    assert_raises(Moissanite::MathError) { k.interpret(1e30) }
  end

  def test_count_evaluates_limit_once
    k = Moissanite.kernel(:limit_once, n: :i64) do |k2, n|
      total = k2.let(0)
      bound = k2.let(n)
      k2.count(bound) do |_i|
        k2.assign(total, total + 1)
        k2.assign(bound, bound + 10) # ループ回数に影響しない
      end
      k2.ret total
    end

    assert_equal 5, k.interpret(5)
  end

  def test_break_exits_innermost_count_only
    k = Moissanite.kernel(:nested, n: :i64) do |k2, n|
      total = k2.let(0)
      k2.count(n) do |_i|
        k2.count(n) do |j|
          k2.break_if j.eq(1)
          k2.assign(total, total + 1)
        end
        k2.assign(total, total + 100)
      end
      k2.ret total
    end

    assert_equal 303, k.interpret(3)
  end

  def test_buffer_bounds_checked_in_oracle
    k = Moissanite.kernel(:oob, buf: :f64_buf, i: :i64) do |k2, buf, i|
      k2.ret buf[i]
    end
    buf = Moissanite::Buffer.f64([1.0, 2.0])

    assert_in_delta(2.0, k.interpret(buf, 1))
    assert_raises(IndexError) { k.interpret(buf, 2) }
    assert_raises(IndexError) { k.interpret(buf, -1) }
  end

  def test_argument_validation
    k = scalar(->(_k, x) { x }, x: :f64)

    assert_raises(ArgumentError) { k.interpret(1.0, 2.0) }
    assert_raises(ArgumentError) { k.interpret('one') }

    ki = scalar(->(_k, n) { n }, n: :i64)

    assert_raises(ArgumentError) { ki.interpret(2**63) }
  end

  # 単項マイナスは 0 - x では代用できない: f64 の -0.0 が +0.0 になってしまう。
  def test_unary_minus_preserves_negative_zero
    negate = scalar(->(_k, x) { -x }, x: :f64)
    subtract = scalar(->(_k, x) { 0.0 - x }, x: :f64)

    assert_equal(-Float::INFINITY, 1.0 / negate.interpret(0.0))
    assert_equal(Float::INFINITY, 1.0 / subtract.interpret(0.0))
    assert_in_delta(-2.5, negate.interpret(2.5))
  end

  def test_unary_minus_wraps_at_i64_min
    negate = scalar(->(_k, n) { -n }, n: :i64)

    assert_equal I64_MIN, negate.interpret(I64_MIN)
    assert_equal(-5, negate.interpret(5))
  end

  def test_math_domain_follows_c_not_ruby
    sqrt = scalar(->(_k, x) { x.sqrt }, x: :f64)

    assert_predicate sqrt.interpret(-1.0), :nan? # Math::DomainError ではなく C の NaN
    assert_in_delta 3.0, sqrt.interpret(9.0)

    log = scalar(->(_k, x) { x.log }, x: :f64)

    assert_predicate log.interpret(-1.0), :nan?
    assert_equal(-Float::INFINITY, log.interpret(0.0))
  end

  def test_math_min_max_avoid_nan_like_fmin
    min = scalar(->(_k, x, y) { x.min(y) }, x: :f64, y: :f64)

    assert_in_delta 2.0, min.interpret(Float::NAN, 2.0)
    assert_in_delta 1.0, min.interpret(1.0, Float::NAN)
    assert_in_delta 1.0, min.interpret(2.0, 1.0)

    max = scalar(->(_k, x, y) { x.max(y) }, x: :f64, y: :f64)

    assert_in_delta 2.0, max.interpret(2.0, Float::NAN)
    assert_in_delta 2.0, max.interpret(1.0, 2.0)
  end

  def test_buffer_roundtrip
    buf = Moissanite::Buffer.f64(4)
    buf.fill(0.5)
    buf[2] = -1.25

    assert_equal [0.5, 0.5, -1.25, 0.5], buf.to_a
    assert_in_delta 0.25, buf.sum
    assert_equal [1.0, 2.0], Moissanite::Buffer.f64([1.0, 2.0]).to_a
  end
end
