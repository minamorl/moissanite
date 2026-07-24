# frozen_string_literal: true

require 'minitest/autorun'
require 'etc'
require 'moissanite'

# 並列実行の契約:
#   - Fiddle::Function 呼び出し中は GVL が解放される (実測でスケーリングを確認)
#   - 互いに素な Buffer#view への同時書き込みは安全 (native レベルで別番地)
#   - スレッド分割した計算は全体計算とビット単位で一致する
class ParallelTest < Minitest::Test
  W = 200
  H = 120
  LIMIT = 200

  def setup
    skip 'no working C toolchain' unless Moissanite::Backend::Cc.available?
  end

  # 分割は座標 (y0) ではなく行オフセット (y_off) で渡す。座標の前送りは
  # 浮動小数の非結合性で ci が ulp 単位でずれ、ビット一致が壊れる。
  # (y + y_off) * dy なら全体実行と式の形が同一なので、分割は構造的に
  # ビット一致する。
  def mandel_grid
    @mandel_grid ||= Moissanite.kernel(:mandel_grid, out: :f64_buf, w: :i64, h: :i64, y_off: :i64, x0: :f64,
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
  end

  def test_sliced_parallel_run_is_bit_identical_to_whole_run
    dx = 3.5 / W
    dy = 2.0 / H
    whole = Moissanite::Buffer.f64(W * H)
    mandel_grid.call(whole, W, H, 0, -2.5, -1.0, dx, dy, LIMIT)

    sliced = Moissanite::Buffer.f64(W * H)
    slices = 4
    rows = H / slices
    Array.new(slices) do |s|
      Thread.new do
        window = sliced.view(s * rows * W, rows * W)
        mandel_grid.call(window, W, rows, s * rows, -2.5, -1.0, dx, dy, LIMIT)
      end
    end.each(&:join)

    assert_equal whole.to_a, sliced.to_a
  end

  def test_view_shares_memory_and_checks_bounds
    base = Moissanite::Buffer.f64([0.0, 1.0, 2.0, 3.0])
    window = base.view(1, 2)

    assert_equal [1.0, 2.0], window.to_a
    window[0] = 9.5

    assert_equal [0.0, 9.5, 2.0, 3.0], base.to_a
    assert_raises(IndexError) { window[2] }
    assert_raises(ArgumentError) { base.view(3, 2) }
    assert_raises(ArgumentError) { base.view(-1, 1) }
  end

  def test_native_calls_release_the_gvl
    skip 'needs >= 2 cores' if Etc.nprocessors < 2

    spin = Moissanite.kernel(:spin, reps: :i64) do |k, reps|
      acc = k.let(0.0)
      k.count(reps) do |i|
        zr = k.let(0.0)
        zi = k.let(0.0)
        k.count(500) do |_j|
          t = k.let((zr * zr) - (zi * zi) + -0.1)
          k.assign(zi, (2.0 * zr * zi) + 0.65)
          k.assign(zr, t)
        end
        k.assign(acc, acc + zr + i.to_f64)
      end
      k.ret acc
    end
    reps = 60_000
    spin.call(100)

    single = elapsed { spin.call(reps) }
    dual = elapsed { Array.new(2) { Thread.new { spin.call(reps) } }.each(&:join) }
    scaling = (single * 2) / dual

    assert_operator scaling, :>, 1.3, "expected GVL release to give >1.3x scaling, got #{scaling.round(2)}x"
  end

  private

  def elapsed
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  end
end
