# frozen_string_literal: true

require 'minitest/autorun'
require 'moissanite'

# 式木の構築規則 (型付け・持ち上げ・検証) のテスト。
class ExprTest < Minitest::Test
  def build_params
    Moissanite::Kernel.build(:t, x: :f64, n: :i64, buf: :f64_buf) do |k, x, n, buf|
      @x = x
      @n = n
      @buf = buf
      k.ret 0
    end
    [@x, @n, @buf]
  end

  def test_literal_lifting_in_arithmetic
    x, n, = build_params

    assert_equal :f64, (x * 2.0).type
    assert_equal :f64, (2.0 * x).type
    assert_equal :f64, (x + 2).type # 正確に表せる Integer は f64 に持ち上がる
    assert_equal :i64, (n + 1).type
    assert_equal :bool, (x > 0.5).type
    assert_equal :bool, n.ne(0).type
  end

  def test_mixed_expr_types_require_explicit_cast
    x, n, = build_params

    assert_raises(Moissanite::TypeMismatch) { x + n }
    assert_equal :f64, (x + n.to_f64).type
    assert_equal :i64, (x.to_i64 + n).type
  end

  def test_lossy_literal_lifting_is_rejected
    x, n, = build_params

    assert_raises(Moissanite::TypeMismatch) { n + 0.5 } # Float は i64 に持ち上げない
    assert_raises(Moissanite::TypeMismatch) { x + ((2**60) + 1) } # f64 で正確に表せない
  end

  def test_modulo_is_i64_only
    x, n, = build_params

    assert_equal :i64, (n % 7).type
    assert_raises(Moissanite::TypeMismatch) { x % 2.0 }
  end

  def test_bool_ops_require_bool
    x, n, = build_params

    assert_equal :bool, ((x > 0.0) & (n > 0)).type
    assert_equal :bool, ((x > 0.0) | (n > 0)).not.type
    assert_raises(Moissanite::TypeMismatch) { x & x }
  end

  def test_buffer_indexing
    _, n, buf = build_params

    assert_equal :f64, buf[n].type
    assert_equal :f64, buf[0].type
    assert_raises(Moissanite::TypeMismatch) { buf[1.5] }
  end

  def test_kernel_requires_trailing_ret
    err = assert_raises(Moissanite::BuildError) do
      Moissanite.kernel(:bad, x: :f64) { |_k, _x| nil }
    end

    assert_match(/ret/, err.message)
  end

  def test_kernel_rejects_mixed_return_types
    assert_raises(Moissanite::BuildError) do
      Moissanite.kernel(:bad, x: :f64) do |k, x|
        k.ret_if x > 0.0, 1
        k.ret 0.5
      end
    end
  end

  def test_kernel_rejects_reserved_param_names
    assert_raises(Moissanite::BuildError) do
      Moissanite.kernel(:bad, double: :f64) { |k, _d| k.ret 0 }
    end
  end

  def test_to_sexp_is_inspectable
    kernel = Moissanite.kernel(:inspectable, x: :f64) do |k, x|
      k.ret x * 2.0
    end
    sexp = kernel.to_sexp

    assert_equal :kernel, sexp[0]
    assert_equal :inspectable, sexp[1]
    assert_equal :f64, sexp[3]
  end
end
