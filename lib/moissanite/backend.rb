# frozen_string_literal: true

module Moissanite
  # ==================================================================
  # Backend — 実行水準の選択。fallback 鎖の掟:
  #
  #   native 系 backend (cc, 将来 gccjit / tcc) → oracle (常に在る)
  #
  # どの環境でも動き、native が使える環境では速い。強制は環境変数
  # MOISSANITE_BACKEND=oracle|cc で行う (差分検証・デバッグ用)。
  # backend は自作コンパイラを持たない — 既製の処理系を FFI / 既存
  # ツールチェーンとして呼ぶだけ、が moissanite の憲法である。
  # ==================================================================
  module Backend
    class Unavailable < Error; end

    module_function

    def compile(kernel)
      chain.each do |backend|
        return backend.compile(kernel) if backend.available?
      end
      raise Unavailable, 'no backend available (oracle should always be available; this is a bug)'
    end

    def chain
      case ENV.fetch('MOISSANITE_BACKEND', nil)
      when 'oracle' then [OracleBackend]
      when 'cc' then [require_available(Cc)]
      when 'tcc' then [require_available(Tcc)]
      when nil then [Cc, Tcc, OracleBackend]
      else raise ArgumentError, "unknown MOISSANITE_BACKEND=#{ENV.fetch('MOISSANITE_BACKEND', nil)}"
      end
    end

    def require_available(backend)
      return backend if backend.available?

      raise Unavailable, "MOISSANITE_BACKEND=#{backend.tag} but that toolchain is not working here"
    end

    # oracle を backend の口に合わせる薄い皮。Oracle は呼び出しごとに
    # 生成する (インタプリタは状態を持つため)。
    module OracleBackend
      Compiled = Struct.new(:kernel) do
        def call(*args) = Oracle.new(kernel).call(*args)
        def backend_name = :oracle
      end

      module_function

      def available? = true
      def compile(kernel) = Compiled.new(kernel)
    end
  end
end
