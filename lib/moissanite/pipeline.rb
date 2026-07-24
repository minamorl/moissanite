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
    attr_reader :arity, :stages, :element

    # 空のパイプライン (入力の要素型と入力本数を決めるだけ)。
    # 最初の段は arity 個の Expr を受け取り 1 つの Expr を返す
    # (2 入力なら zip 相当)。以降の段は 1 入力 1 出力。
    def self.f64(arity: 1)
      of(:f64, arity: arity)
    end

    def self.i64(arity: 1)
      of(:i64, arity: arity)
    end

    # 入力の要素型を選ぶ。出力の要素型は宣言しない — 段を適用した結果の
    # 型から決まる (f64 を読んで i64 を書くカーネルもそのまま書ける)。
    def self.of(element, arity: 1)
      raise ArgumentError, "element must be :f64 or :i64, got #{element.inspect}" unless SCALAR_TYPES.include?(element)
      raise ArgumentError, 'element must not be :bool' if element == :bool
      raise ArgumentError, "arity must be 1 or 2, got #{arity}" unless [1, 2].include?(arity)

      new(element, arity, [])
    end

    def initialize(element, arity, stages)
      @element = element
      @arity = arity
      @stages = stages.freeze
    end

    # 段を足した新しい Pipeline を返す (不変)。
    def map(&block)
      raise ArgumentError, 'map requires a block' unless block

      self.class.new(@element, @arity, @stages + [block])
    end

    def size
      @stages.size
    end

    # 段を適用した結果のスカラ型。段は純関数なので、ダミーの Param に
    # 適用して型だけ読み取れる (実行はしない — 式木を組むだけ)。
    def result_type
      return @element if @stages.empty?

      probes = Array.new(@arity) { |j| Param.new(type: @element, name: :"probe#{j}", index: j) }
      value = @stages.first.call(*probes)
      @stages.drop(1).reduce(value) { |acc, stage| stage.call(acc) }.type
    end

    # 全段を 1 カーネルへ融合する: 入力を 1 回読み、全段を適用し、
    # 1 回書く。out, in0.., n(:i64) のシグネチャ (バッファ型は要素型に従う)。
    def fuse(name = :fused)
      raise BuildError, 'pipeline has no stages' if @stages.empty?

      build_kernel(name) do |k, outputs, inputs|
        outputs.call(apply_stages(k, inputs))
      end
    end

    # 全段 + 畳み込みを 1 カーネルへ融合する: 入力を 1 回読み、スカラを返す。
    # **出力バッファが存在しない** — 中間結果は一切メモリに触れない。
    # これが融合の効果が最大になる形で、ライブラリ合成 (map してから sum) が
    # 中間配列を確保して往復するのと対照的。
    #
    # reducer は (acc_expr, value_expr) -> Expr の純関数。累積器の型は
    # init のリテラル型 (Float なら f64、Integer なら i64) で決まる。
    # 畳み込みは添字順の逐次累積なので、oracle と native で結合順が一致し
    # 浮動小数でもビット一致する。
    #
    #   pipe.reduce(0.0) { |acc, v| acc + v }   # 融合した総和
    #   pipe.reduce(0) { |acc, v| acc + v }     # i64 で数える
    def reduce(init, name = :reduced, &reducer)
      raise ArgumentError, 'reduce requires a block' unless reducer

      seed = Expr.lift_any(init)
      Moissanite.kernel(name, **signature(output: false)) do |k, *rest|
        count = rest.pop
        acc = k.let(seed)
        k.count(count) do |i|
          value = apply_stages(k, rest.map { |buf| k.let(buf[i]) })
          k.assign(acc, reducer.call(acc, value))
        end
        k.ret acc
      end
    end

    # 総和 (reduce の最頻ケース)。累積器は段の結果型に合わせる。
    def sum(name = :summed)
      reduce(result_type == :i64 ? 0 : 0.0, name) { |acc, value| acc + value }
    end

    # 段ごとに独立したカーネルを作る (= 段数だけメモリを往復する)。
    # 融合の対照群であり、「AOT ライブラリの関数を段ごとに呼ぶ」
    # 実運用形そのものでもある。中間バッファの要素型は段ごとに変わりうる
    # ので、各段の入力型はひとつ前の段の結果型になる。
    def stage_kernels(name = :stage)
      element = @element
      @stages.each_with_index.map do |stage, index|
        arity = index.zero? ? @arity : 1
        single = Pipeline.new(element, arity, [stage])
        element = single.result_type
        single.send(:build_kernel, :"#{name}#{index}") do |k, outputs, inputs|
          outputs.call(k.let(stage.call(*inputs)))
        end
      end
    end

    private

    # 段を順に適用する。各段の結果を let で束ねるのは、段が入力を複数回
    # 参照したとき (v * v など) に式木が指数的に膨らむのを防ぐため。
    def apply_stages(builder, inputs)
      if @stages.empty?
        raise BuildError, 'a 2-input pipeline needs at least one stage to combine its inputs' if inputs.size > 1

        return inputs.first
      end

      value = builder.let(@stages.first.call(*inputs))
      @stages.drop(1).each { |stage| value = builder.let(stage.call(value)) }
      value
    end

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

    # [out,] in0..inN, n — 宣言順がそのまま呼び出し順になる。
    # 入力は宣言した要素型、出力は段を適用した結果型のバッファ。
    # 畳み込み (reduce) はスカラを返すので出力バッファを取らない。
    def signature(output: true)
      params = {}
      params[:out] = buffer_type(result_type) if output
      @arity.times { |j| params[:"in#{j}"] = buffer_type(@element) }
      params[:n] = :i64
      params
    end

    def buffer_type(element)
      element == :i64 ? :i64_buf : :f64_buf
    end
  end
end
