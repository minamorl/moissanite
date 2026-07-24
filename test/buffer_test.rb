# frozen_string_literal: true

require 'minitest/autorun'
require 'moissanite'

# Buffer の要素型 (:f64 / :i64) と、型の取り違えを入口で弾く契約。
# どちらも 8 バイトなので、native では取り違えが「黙った読み替え」に
# なってしまう — だから型検査は呼び出し前でなければ意味がない。
class BufferTest < Minitest::Test
  def test_i64_buffer_roundtrip
    buf = Moissanite::Buffer.i64([1, -2, 3])

    assert_equal :i64, buf.element_type
    assert_equal [1, -2, 3], buf.to_a
    buf[1] = -(2**62)

    assert_equal(-(2**62), buf[1])
  end

  # 式言語が「型混合は常に明示」なので、バッファ書き込みも同じ厳しさ。
  # Float の暗黙の切り捨て (Integer(1.5) == 1) は受け入れない。
  def test_i64_buffer_rejects_out_of_range_and_non_integers
    buf = Moissanite::Buffer.i64(2)

    assert_raises(ArgumentError) { buf[0] = 2**63 }
    assert_raises(ArgumentError) { buf[0] = 'x' }
    assert_raises(ArgumentError) { buf[0] = 1.5 }
  end

  def test_f64_buffer_still_coerces_integers
    buf = Moissanite::Buffer.f64([1, 2])

    assert_equal [1.0, 2.0], buf.to_a
  end

  def test_view_carries_element_type
    window = Moissanite::Buffer.i64([1, 2, 3, 4]).view(1, 2)

    assert_equal :i64, window.element_type
    assert_equal [2, 3], window.to_a
  end

  def test_unknown_element_type_and_bad_size_are_rejected
    assert_raises(ArgumentError) { Moissanite::Buffer.build(:f32, 4) }
    assert_raises(ArgumentError) { Moissanite::Buffer.f64(0) }
    assert_raises(ArgumentError) { Moissanite::Buffer.f64('four') }
  end

  # --- kernel との接続 -------------------------------------------------

  def counting_kernel
    Moissanite.kernel(:above, hits: :i64_buf, xs: :f64_buf, n: :i64, threshold: :f64) do |k, hits, xs, n, threshold|
      k.count(n) do |i|
        k.store(hits, i, k.select(xs[i] > threshold, 1, 0))
      end
      k.ret 0
    end
  end

  def test_i64_buffer_kernel_matches_oracle
    kernel = counting_kernel
    xs = Moissanite::Buffer.f64([0.5, 2.0, -1.0, 3.5])
    native = Moissanite::Buffer.i64(4)
    oracle = Moissanite::Buffer.i64(4)
    kernel.call(native, xs, 4, 1.0)
    kernel.interpret(oracle, xs, 4, 1.0)

    assert_equal [0, 1, 0, 1], native.to_a
    assert_equal oracle.to_a, native.to_a
  end

  def test_buffer_element_type_mismatch_is_rejected_before_running
    kernel = counting_kernel
    xs = Moissanite::Buffer.f64([0.5])

    error = assert_raises(ArgumentError) { kernel.call(Moissanite::Buffer.f64(1), xs, 1, 1.0) }
    assert_match(/expected a i64 buffer/, error.message)
    assert_raises(ArgumentError) { kernel.call(Moissanite::Buffer.i64(1), Moissanite::Buffer.i64(1), 1, 1.0) }
  end

  def test_loads_from_an_i64_buffer_are_i64_typed
    Moissanite.kernel(:typed, ints: :i64_buf, reals: :f64_buf, n: :i64) do |k, ints, reals, n|
      assert_equal :i64, ints[0].type
      assert_equal :f64, reals[0].type
      # 型混合は明示 cast を要求する (バッファ越しでも同じ規則)。
      assert_raises(Moissanite::TypeMismatch) { ints[0] + reals[0] }
      assert_equal :f64, (ints[0].to_f64 + reals[0]).type
      k.count(n) { |i| k.store(ints, i, ints[i] + 1) } # リテラルは要素型へ持ち上がる
      k.ret 0
    end
  end

  def test_storing_the_wrong_scalar_type_is_rejected
    assert_raises(Moissanite::TypeMismatch) do
      Moissanite.kernel(:bad, ints: :i64_buf, reals: :f64_buf, n: :i64) do |k, ints, reals, n|
        k.count(n) { |i| k.store(ints, i, reals[i]) }
        k.ret 0
      end
    end
  end

  def test_extent_guard_covers_i64_buffers_too
    kernel = counting_kernel
    xs = Moissanite::Buffer.f64([0.5, 1.5])
    hits = Moissanite::Buffer.i64(2)

    refute_nil kernel.extent_guard
    assert_raises(ArgumentError) { kernel.call(hits, xs, 3, 1.0) }
  end
end
