# frozen_string_literal: true

module Moissanite
  # ==================================================================
  # Pipeline — 要素ごとの変換の連なり。各段は「Expr -> Expr」の純関数
  # (ただの Ruby ブロック) なので、段の合成は関数合成そのものである。
  #
  # 中心的な事実: 段が *データ* である以上、実行時に組んだパイプラインを
  # 1 つのループ本体へ畳み込める (= 融合 / fusion)。段ごとに独立の
  # カーネルを呼ぶと段数だけメモリを往復するが、融合すれば 1 パスで済む。
  # 大きな配列では帯域が律速なので、この差はそのまま速度差になる。
  #
  # AOT 言語も、パイプライン全体がコンパイル時に見えていれば融合できる
  # (イテレータ連鎖・式テンプレート)。だが構成が *実行時* に決まる場合
  # (設定・クエリ・プラグイン連鎖) は動的ディスパッチ越しの多段パスに
  # 落ちる。moissanite はそこで融合できる — 段が値だから。
  #
  #   pipe = Moissanite::Pipeline.f64.map { |v| (v * 2.0) + 1.0 }
  #                                  .map(&:sqrt)
  #                                  .map { |v| v * scale }   # scale は実行時定数
  #   kernel = pipe.fuse          # 1 カーネル / 1 パス
  #   kernel.call(out, xs, n)
  # ==================================================================
  class Pipeline
    attr_reader :arity, :stages

    # arity 個の f64 バッファを入力に取る空のパイプライン。
    # 最初の段は arity 個の Expr を受け取り 1 つの Expr を返す
    # (2 入力なら zip 相当)。以降の段は 1 入力 1 出力。
    def self.f64(arity: 1)
      raise ArgumentError, "arity must be 1 or 2, got #{arity}" unless [1, 2].include?(arity)

      new(arity, [])
    end

    def initialize(arity, stages)
      @arity = arity
      @stages = stages.freeze
    end

    # 段を足した新しい Pipeline を返す (不変)。
    def map(&block)
      raise ArgumentError, 'map requires a block' unless block

      self.class.new(@arity, @stages + [block])
    end

    def size
      @stages.size
    end

    # 全段を 1 カーネルへ融合する: 入力を 1 回読み、全段を適用し、
    # 1 回書く。out(:f64_buf), in0..(:f64_buf), n(:i64) のシグネチャ。
    def fuse(name = :fused)
      raise BuildError, 'pipeline has no stages' if @stages.empty?

      stages = @stages
      build_kernel(name) do |k, outputs, inputs|
        value = k.let(stages.first.call(*inputs))
        stages.drop(1).each { |stage| value = k.let(stage.call(value)) }
        outputs.call(value)
      end
    end

    # 段ごとに独立したカーネルを作る (= 段数だけメモリを往復する)。
    # 融合の対照群であり、「AOT ライブラリの関数を段ごとに呼ぶ」
    # 実運用形そのものでもある。
    def stage_kernels(name = :stage)
      @stages.each_with_index.map do |stage, index|
        arity = index.zero? ? @arity : 1
        Pipeline.new(arity, [stage]).send(:build_kernel, :"#{name}#{index}") do |k, outputs, inputs|
          outputs.call(k.let(stage.call(*inputs)))
        end
      end
    end

    private

    # out, in0.., n のシグネチャで要素ごとループのカーネルを組む。
    # 各段の結果を k.let で束ねるのは、段が入力を複数回参照したとき
    # (v * v など) に式木が指数的に膨らむのを防ぐため。
    def build_kernel(name, &body)
      Moissanite.kernel(name, **signature) do |k, out, *rest|
        count = rest.pop
        k.count(count) do |i|
          inputs = rest.map { |buf| k.let(buf[i]) }
          body.call(k, ->(value) { k.store(out, i, value) }, inputs)
        end
        k.ret 0
      end
    end

    # out, in0..inN, n — 宣言順がそのまま呼び出し順になる。
    def signature
      params = { out: :f64_buf }
      @arity.times { |j| params[:"in#{j}"] = :f64_buf }
      params[:n] = :i64
      params
    end
  end
end
