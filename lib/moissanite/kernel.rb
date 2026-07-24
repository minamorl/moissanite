# frozen_string_literal: true

require 'etc'

module Moissanite
  # ==================================================================
  # Kernel — 名前付きの native レベル関数。実体は「型付きシグネチャ + 文の
  # リスト」という純データで、実行水準は backend が決める:
  #
  #   kernel.call(*args)       — 自動選択 (native があれば native、無ければ oracle)
  #   kernel.interpret(*args)  — 純 Ruby oracle (意味論の正典) で実行
  #   kernel.source_c          — cc backend が発行する C を覗く (検査可能性)
  #
  # oracle と native の等価は差分検証 (test/equivalence_test) が縛る。
  # ==================================================================
  class Kernel
    attr_reader :name, :params, :body, :return_type

    # C 予約語など、backend で衝突する名前を入口で弾く (名前は C 側に
    # そのまま出るため)。生成する局所変数名は id つきで衝突しない。
    RESERVED = %w[
      auto break case char const continue default do double else enum extern
      float for goto if inline int long register restrict return short signed
      sizeof static struct switch typedef union unsigned void volatile while
      int64_t moissanite_kernel
    ].freeze

    def self.build(name = :kernel, **param_types, &block)
      raise BuildError, 'kernel requires a block' unless block

      params = param_types.each_with_index.map do |(pname, ptype), index|
        raise TypeMismatch, "param #{pname}: #{ptype} not in #{PARAM_TYPES}" unless PARAM_TYPES.include?(ptype)
        raise BuildError, "param name #{pname} is not usable" unless pname.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
        raise BuildError, "param name #{pname} is reserved" if RESERVED.include?(pname.to_s)

        Param.new(type: ptype, name: pname, index: index)
      end
      builder = Builder.new
      block.call(builder, *params)
      new(name, params, builder.statements)
    end

    def initialize(name, params, body)
      @name = name.to_sym
      @params = params.freeze
      @body = body.freeze
      @return_type = infer_return_type
      @compiled = nil
      @mutex = Mutex.new
      validate!
    end

    def call(*)
      compiled.call(*)
    end

    def interpret(*)
      Oracle.new(self).call(*)
    end

    # 添字範囲を分割して素の Thread で並列実行する (実行器は BandRun)。
    # 分割してよい根拠は extent_guard が証明した性質そのもの。
    #
    # 戻り値は各バンドの戻り値の配列。map 形では 0 の列なので捨ててよい。
    # reduce 形では部分結果が返るが、**その合成は結合順が変わるので逐次
    # 実行とビット一致しない** — 受け入れるかは呼び手が決めること。
    def call_parallel(*args, threads: nil, band_size: nil)
      guard = extent_guard
      raise BuildError, "#{@name}: call_parallel needs a simple elementwise shape" unless guard

      total = Arguments.validate(self, args, native: false)[guard.count_index]
      return [] unless total.positive?

      plan = BandRun::Plan.new(total: total, threads: threads, band_size: band_size)
      BandRun.call(self, guard, args, plan)
    end

    def backend_name
      compiled.backend_name
    end

    def source_c
      Backend::Cc.new(self).source
    end

    def to_sexp
      [:kernel, @name, @params.map(&:to_sexp), @return_type, @body.map(&:to_sexp)]
    end

    # 単純な要素ごと形なら安全条件 (n <= 各バッファ長) を返す。
    # それ以外は nil = 何も主張しない (ExtentGuard を参照)。
    def extent_guard
      @extent_guard = ExtentGuard.analyze(@body) || :none if @extent_guard.nil?
      @extent_guard == :none ? nil : @extent_guard
    end

    # 宣言順の [型, ...]。backend の ABI 決定と引数検証が共有する。
    def param_types
      @params.map(&:type)
    end

    private

    def compiled
      @compiled || @mutex.synchronize { @compiled ||= Backend.compile(self) }
    end

    # 返却型は全 Ret の一致から推論する (f64 / i64 のみ)。
    def infer_return_type
      types = collect_ret_types(@body).uniq
      raise BuildError, 'kernel has no ret' if types.empty?
      raise BuildError, "ret types differ: #{types.inspect}" if types.size > 1
      raise BuildError, 'bool return is not supported' unless %i[f64 i64].include?(types.first)

      types.first
    end

    def collect_ret_types(stmts)
      stmts.flat_map do |s|
        case s
        when Ret then [s.expr.type]
        when If then collect_ret_types(s.then_stmts) + collect_ret_types(s.else_stmts)
        when Count then collect_ret_types(s.body)
        else []
        end
      end
    end

    # 末尾が Ret であることを構造で要求する。これで「返り値なしで
    # 落ちる」経路が oracle にも native にも存在しなくなる。
    def validate!
      raise BuildError, 'kernel body must end with k.ret' unless @body.last.is_a?(Ret)
    end
  end

  def self.kernel(name = :kernel, **param_types, &)
    Kernel.build(name, **param_types, &)
  end
end
