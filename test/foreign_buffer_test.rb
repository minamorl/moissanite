# frozen_string_literal: true

require 'minitest/autorun'
require 'moissanite'

# Buffer.wrap — 他所が所有するメモリの採用。
#
# malloc した領域しか扱えないなら、moissanite のカーネルは自分で作った
# データにしか触れない。wrap があると、numpy の ndarray・mmap・他の C
# ライブラリが返した領域を **コピーせずに** そのまま計算対象にできる。
#
# 危険は二つあり、どちらも入口で塞ぐ:
#   - 所有権の取り違え (wrap した Buffer は決して free しない)
#   - 生存期間 (元の持ち主が先に GC されると解放済みの番地を踏む)
class ForeignBufferTest < Minitest::Test
  def test_wrap_shares_memory_with_the_owner
    source = Moissanite::Buffer.f64([1.0, 2.0, 3.0])
    foreign = Moissanite::Buffer.wrap(source.ptr, 3, :f64, owner: source)

    assert_equal [1.0, 2.0, 3.0], foreign.to_a

    # 同じ実体なので、どちらへの書き込みも両方から見える。
    foreign[0] = 9.0
    source[2] = -1.0

    assert_in_delta 9.0, source[0]
    assert_in_delta(-1.0, foreign[2])
  end

  def test_wrap_accepts_a_bare_address
    source = Moissanite::Buffer.i64([7, 8])
    foreign = Moissanite::Buffer.wrap(source.ptr.to_i, 2, :i64, owner: source)

    assert_equal [7, 8], foreign.to_a
  end

  # wrap した Buffer は領域を所有しない。owner: に渡した持ち主を掴んで
  # いるので、こちらの参照しか残っていなくても持ち主は GC されない
  # (されていれば RUBY_FREE で解放され、この読み出しは壊れた値になる)。
  def test_wrap_keeps_the_owner_alive
    foreign = build_foreign_buffer_dropping_the_local_reference
    GC.start

    assert_equal [4.0, 5.0, 6.0], foreign.to_a
  end

  def test_wrap_rejects_null_unaligned_and_bad_arguments
    source = Moissanite::Buffer.f64([1.0, 2.0])

    assert_raises(ArgumentError) { Moissanite::Buffer.wrap(0, 2, :f64) }
    # double* / int64_t* として読む領域なので、8 バイト境界を外れた番地は
    # C の未定義動作になる — 走らせる前に弾く。
    assert_raises(ArgumentError) { Moissanite::Buffer.wrap(source.ptr.to_i + 1, 1, :f64) }
    assert_raises(ArgumentError) { Moissanite::Buffer.wrap(source.ptr, 2, :f32) }
    assert_raises(ArgumentError) { Moissanite::Buffer.wrap(source.ptr, 0, :f64) }
    assert_raises(ArgumentError) { Moissanite::Buffer.wrap(source.ptr, 'two', :f64) }
  end

  # u8 は幅 1 なので整列の制約が無く、どの番地からでも採用できる。
  # ネットワークバッファの途中を指すのはむしろ普通の使い方 (ヘッダを
  # 読み飛ばした残り、など) なので、8 バイト境界を要求してはいけない。
  def test_wrap_adopts_bytes_at_any_address
    owner = Moissanite::Buffer.bytes('hello world')
    foreign = Moissanite::Buffer.wrap(Fiddle::Pointer.new(owner.ptr.to_i + 1), 4, :u8, owner: owner)

    assert_equal 'ello', foreign.to_bytes
    assert_equal 'll', foreign.view(1, 2).to_bytes
  end

  # 採用したバイト列がそのまま native カーネルの入力になること
  # (幅が正しく伝わっていないと oracle と native がずれる)。
  def test_native_kernel_reads_through_a_wrapped_u8_buffer
    kernel = Moissanite.kernel(:bytesum, buf: :u8_buf, n: :i64) do |k, buf, n|
      acc = k.let(0)
      k.count(n) { |i| k.assign(acc, acc + buf[i]) }
      k.ret acc
    end

    owner = Moissanite::Buffer.bytes('hello world')
    foreign = Moissanite::Buffer.wrap(Fiddle::Pointer.new(owner.ptr.to_i + 1), 4, :u8, owner: owner)

    assert_equal 'ello'.bytes.sum, kernel.interpret(foreign, 4)
    assert_equal kernel.interpret(foreign, 4), kernel.call(foreign, 4)
  end

  def test_view_of_a_wrapped_buffer_stays_zero_copy
    source = Moissanite::Buffer.f64([1.0, 2.0, 3.0, 4.0])
    window = Moissanite::Buffer.wrap(source.ptr, 4, :f64, owner: source).view(2, 2)

    assert_equal [3.0, 4.0], window.to_a
    window[0] = 0.5

    assert_in_delta 0.5, source[2]
  end

  # 本題: native カーネルが「他所のメモリ」へ直接書く。
  def test_native_kernel_writes_through_a_wrapped_buffer
    kernel = Moissanite.kernel(:scale, dst: :f64_buf, src: :f64_buf, k: :f64, n: :i64) do |b, dst, src, k, n|
      b.count(n) { |i| b.store(dst, i, src[i] * k) }
      b.ret 0
    end
    src = Moissanite::Buffer.f64([1.0, 2.0, 3.0, 4.0])
    dst = Moissanite::Buffer.f64(4)

    kernel.call(
      Moissanite::Buffer.wrap(dst.ptr, 4, :f64, owner: dst),
      Moissanite::Buffer.wrap(src.ptr, 4, :f64, owner: src),
      2.5, 4
    )

    # 書き込みは wrap した Buffer 越しに行われたが、実体は dst のもの。
    assert_equal [2.5, 5.0, 7.5, 10.0], dst.to_a
  end

  # 採用したメモリでも要素型の取り違えは入口で弾かれる (native では
  # どちらも 8 バイトなので黙った読み替えになってしまう)。
  def test_wrapped_buffer_still_type_checks_at_the_call_boundary
    kernel = Moissanite.kernel(:double, dst: :f64_buf, src: :f64_buf, n: :i64) do |b, dst, src, n|
      b.count(n) { |i| b.store(dst, i, src[i] * 2.0) }
      b.ret 0
    end
    ints = Moissanite::Buffer.i64([1, 2])
    wrapped = Moissanite::Buffer.wrap(ints.ptr, 2, :i64, owner: ints)

    assert_raises(ArgumentError) { kernel.call(Moissanite::Buffer.f64(2), wrapped, 2) }
  end

  private

  def build_foreign_buffer_dropping_the_local_reference
    owner = Moissanite::Buffer.f64([4.0, 5.0, 6.0])
    Moissanite::Buffer.wrap(owner.ptr, 3, :f64, owner: owner)
  end
end
