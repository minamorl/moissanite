# frozen_string_literal: true

require 'etc'

module Moissanite
  # ==================================================================
  # BandRun — 添字範囲をバンドに割り、素の Thread で並列に走らせる実行器。
  #
  # 分割してよい根拠は ExtentGuard が証明した性質そのもの: 「全バッファ
  # 添字がループ変数」なら、添字範囲を分ければ触るメモリも分かれる。
  # 安全性の解析と並列性の解析が同一なのは偶然ではない — どちらも
  # 「i 番目の出力は i 番目の入力にしか依存しない」を見ている。
  #
  # Fiddle が native 実行中に GVL を解放するので、Ractor も C スレッドも
  # 要らない。バンドをワーカ数より細かく刻んで Queue で配るのは、静的等分
  # だと重いバンドを引いたスレッドだけが走り続けて他が遊ぶため
  # (mandelbrot で実測した)。
  # ==================================================================
  class BandRun
    BANDS_PER_WORKER = 4

    # この実行をどう刻むか (要素数・ワーカ数・バンド幅)。nil は既定に任せる。
    Plan = Data.define(:total, :threads, :band_size)

    def self.call(kernel, guard, args, plan)
      new(kernel, guard, args, plan).run
    end

    def initialize(kernel, guard, args, plan)
      @kernel = kernel
      @guard = guard
      @args = args
      @total = plan.total
      @workers = (plan.threads || Etc.nprocessors).clamp(1, @total)
      @band_size = plan.band_size || default_band_size
    end

    def run
      bands = split
      queue = Queue.new
      bands.each_with_index { |band, index| queue << [index, band] }
      results = Array.new(bands.size)
      Array.new([@workers, bands.size].min) { worker(queue, results) }.each(&:join)
      results
    end

    private

    def default_band_size
      [(@total + (@workers * BANDS_PER_WORKER) - 1) / (@workers * BANDS_PER_WORKER), 1].max
    end

    def split
      (0...@total).step(@band_size).map { |start| [start, [@band_size, @total - start].min] }
    end

    def worker(queue, results)
      Thread.new do
        loop do
          index, band = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          results[index] = @kernel.call(*band_args(*band))
        end
      end
    end

    # バンド [start, len) 用の引数: 各バッファをその窓に、要素数を len に。
    def band_args(start, len)
      sliced = @args.dup
      @guard.buffer_indices.each { |index| sliced[index] = sliced[index].view(start, len) }
      sliced[@guard.count_index] = len
      sliced
    end
  end
end
