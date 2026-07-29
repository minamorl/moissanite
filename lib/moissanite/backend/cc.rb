# frozen_string_literal: true

require 'digest'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'fiddle'

module Moissanite
  module Backend
    class CompileError < Error; end

    # ================================================================
    # Cc backend — 式木を C に落とし、システムの C コンパイラ (-O3) で
    # 共有オブジェクトにして dlopen し、Fiddle::Function として呼ぶ。
    #
    # コンパイラは書かない。GCC/Clang の最適化器・ベクトル化器を
    # そのまま相続する。生成物は source の SHA-256 でコンテンツ
    # アドレスされ、同じ式木は二度とコンパイルされない。
    #
    # oracle との意味論一致のための旗 (差分検証が成立する条件):
    #   -fwrapv          — i64 の符号つきオーバーフローを wrap と定義
    #   -ffp-contract=off — FMA 縮約を禁止し f64 を Ruby Float とビット一致に
    # ================================================================
    Compiled = Struct.new(:kernel, :fn, :handle, :tag) do
      def call(*args) = fn.call(*Arguments.validate(kernel, args, native: true))
      def backend_name = tag
    end

    # ----------------------------------------------------------------
    # Toolchain — 共有パイプライン: 発行 C → 外部コンパイラ → dlopen →
    # Fiddle::Function。Cc / Tcc が extend し、command / tag だけを
    # 差し替える。生成物は source の SHA-256 + tag でコンテンツアドレス
    # され、同じ式木は (toolchain ごとに) 二度とコンパイルされない。
    # ----------------------------------------------------------------
    module Toolchain
      def available?
        @available = probe if @available.nil?
        @available
      end

      def compile(kernel)
        so_path = ensure_compiled(Cc::Emitter.new(kernel).source)
        handle = Fiddle.dlopen(so_path)
        fn = Fiddle::Function.new(
          handle[Cc::SYMBOL],
          kernel.param_types.map { |t| Cc::FIDDLE_TYPE.fetch(t) },
          Cc::FIDDLE_TYPE.fetch(kernel.return_type)
        )
        Compiled.new(kernel, fn, handle, tag)
      end

      # 生成物はコンテンツアドレス (source の SHA-256 + toolchain) された
      # 共有キャッシュに置く。ここで素朴に共有パスへ直接書くと競走になる:
      # fork するアプリサーバや並列テストでは、同じ式木を複数プロセスが
      # 同時にコンパイルしうるので、書きかけの .so を別プロセスが dlopen
      # してしまう。一意な一時パスへ出してから rename で差し込む
      # (同一ファイルシステム上の rename は不可分なので、他プロセスから
      # 見えるのは「無い」か「完成品」だけになる)。
      def ensure_compiled(source)
        dir = cache_dir
        digest = Digest::SHA256.hexdigest(source)
        so_path = File.join(dir, "#{digest}-#{tag}.so")
        return so_path if File.exist?(so_path)

        build_atomically(dir, digest, source, so_path)
        so_path
      end

      def build_atomically(dir, digest, source, so_path)
        stem = File.join(dir, "#{digest}-#{tag}-#{unique_suffix}")
        c_path = "#{stem}.c"
        staged_so = "#{stem}.so"
        File.write(c_path, source)
        run_compiler(c_path, staged_so)
        File.rename(staged_so, so_path)
        # 発行した C は検査できるよう残す (source_c と同じ内容)。
        File.rename(c_path, File.join(dir, "#{digest}.c"))
      ensure
        FileUtils.rm_f([c_path, staged_so].compact)
      end

      # プロセス・スレッド・呼び出しをまたいで衝突しない接尾辞。
      def unique_suffix
        @suffix_mutex ||= Mutex.new
        serial = @suffix_mutex.synchronize { @suffix_serial = (@suffix_serial || 0) + 1 }
        "#{Process.pid}-#{serial}"
      end

      def run_compiler(c_path, so_path)
        cmd = command(c_path, so_path)
        _out, err, status = Open3.capture3(*cmd)
        raise CompileError, "#{cmd.join(' ')}\n#{err}" unless status.success? && File.exist?(so_path)
      end

      def cache_dir
        dir = ENV['MOISSANITE_CACHE_DIR'] || File.join(Dir.tmpdir, "moissanite-#{Process.uid}")
        FileUtils.mkdir_p(dir, mode: 0o700)
        dir
      end

      def probe
        ensure_compiled("int #{Cc::SYMBOL}(void) { return 0; }\n")
        true
      rescue StandardError
        false
      end
    end

    module Cc
      C_TYPE = {
        f64: 'double', i64: 'int64_t',
        f64_buf: 'double*', i64_buf: 'int64_t*', u8_buf: 'uint8_t*'
      }.freeze
      FIDDLE_TYPE = {
        f64: Fiddle::TYPE_DOUBLE, i64: Fiddle::TYPE_LONG_LONG,
        f64_buf: Fiddle::TYPE_VOIDP, i64_buf: Fiddle::TYPE_VOIDP, u8_buf: Fiddle::TYPE_VOIDP
      }.freeze
      CFLAGS = %w[-O3 -fPIC -shared -fwrapv -ffp-contract=off].freeze
      SYMBOL = 'moissanite_kernel'

      extend Toolchain

      def self.tag = :cc

      def self.command(c_path, so_path)
        [compiler, *CFLAGS, '-o', so_path, c_path, '-lm']
      end

      def self.compiler
        ENV['MOISSANITE_CC'] || ENV['CC'] || RbConfig::CONFIG['CC'] || 'cc'
      end

      def self.new(kernel)
        Emitter.new(kernel)
      end

      # ----------------------------------------------------------------
      # Emitter — 式木 → C ソース。純粋な文字列変換 (副作用なし)。
      # ----------------------------------------------------------------
      class Emitter
        BINOP_C = {
          :+ => '+', :- => '-', :* => '*', :/ => '/', :% => '%',
          lt: '<', le: '<=', gt: '>', ge: '>=', eq: '==', ne: '!=',
          and: '&&', or: '||'
        }.freeze

        def initialize(kernel)
          @kernel = kernel
        end

        MATH_C = {
          sqrt: 'sqrt', sin: 'sin', cos: 'cos', exp: 'exp', log: 'log',
          abs: 'fabs', min: 'mo_fmin', max: 'mo_fmax'
        }.freeze

        # libm の fmin/fmax は gcc が要素ごとの PLT 呼び出しへ落とし、
        # ループのベクトル化ごと潰す (4 段パイプラインの実測で 2.5x の損失)。
        # 意味論 (NaN 側を避ける = fmin/fmax の規則) を一切変えずにインライン
        # 展開するため、同じ規則を static inline で自前に持つ。
        # sqrt / sin / exp などは gcc が適切に扱う (sqrt は sqrtpd へベクトル化
        # される) ので libm のまま使う。
        HELPERS = {
          'mo_fmin' => <<~C,
            static inline double mo_fmin(double a, double b) {
              if (a != a) return b;
              if (b != b) return a;
              return a < b ? a : b;
            }
          C
          'mo_fmax' => <<~C
            static inline double mo_fmax(double a, double b) {
              if (a != a) return b;
              if (b != b) return a;
              return a > b ? a : b;
            }
          C
        }.freeze

        def source
          params = @kernel.params.map { |p| "#{C_TYPE.fetch(p.type)} #{p.name}" }.join(', ')
          body = block(@kernel.body, 1)
          helpers = HELPERS.filter_map { |name, code| code if body.include?(name) }.join("\n")
          <<~C
            #include <stdint.h>
            #include <math.h>

            #{helpers}#{C_TYPE.fetch(@kernel.return_type)} #{SYMBOL}(#{params}) {
            #{body}}
          C
        end

        private

        def block(stmts, depth)
          stmts.map { |s| stmt(s, depth) }.join
        end

        def stmt(node, depth)
          pad = '  ' * depth
          case node
          when Let then "#{pad}#{C_TYPE.fetch(node.local.type)} #{name(node.local)} = #{expr(node.expr)};\n"
          when Assign then "#{pad}#{name(node.local)} = #{expr(node.expr)};\n"
          when Store then "#{pad}#{node.buf.name}[#{expr(node.index)}] = #{cast_in(node, expr(node.expr))};\n"
          when If then if_stmt(node, depth, pad)
          when Count then count_stmt(node, depth, pad)
          when Break then "#{pad}break;\n"
          when Ret then "#{pad}return #{expr(node.expr)};\n"
          else raise Error, "unknown statement #{node.inspect}"
          end
        end

        # u8 バッファは出入りの両端でキャストを通す。他のバッファは素通し。
        #
        # 書き: 下位 8bit へ切り詰める (oracle の value & 0xFF と同じ意味論)。
        # 読み: uint8_t は C の整数昇格で int になるので int64_t へ広げる。
        #   広げないと buf[i]*buf[j]*... が int 演算になり、式言語が :i64 と
        #   言っている型と食い違う (差分検証の u8 widening ケースが捕まえる)。
        def cast_in(node, src) = node.buf.type == :u8_buf ? "((uint8_t)(#{src}))" : src
        def cast_out(node, src) = node.buf.type == :u8_buf ? "((int64_t)#{src})" : src

        def if_stmt(node, depth, pad)
          out = "#{pad}if (#{expr(node.cond)}) {\n#{block(node.then_stmts, depth + 1)}#{pad}}"
          out += " else {\n#{block(node.else_stmts, depth + 1)}#{pad}}" unless node.else_stmts.empty?
          "#{out}\n"
        end

        # limit は入口で一度だけ評価する (oracle と同じ意味論)。
        def count_stmt(node, depth, pad)
          i = name(node.var)
          n = "n#{node.var.id}"
          header = "#{pad}for (int64_t #{i} = 0, #{n} = #{expr(node.limit)}; #{i} < #{n}; #{i}++) {\n"
          "#{header}#{block(node.body, depth + 1)}#{pad}}\n"
        end

        def name(local)
          "#{local.name}_#{local.id}"
        end

        def expr(node)
          case node
          when Const then const(node)
          when Param then node.name.to_s
          when Local then name(node)
          when BinOp then "(#{expr(node.lhs)} #{BINOP_C.fetch(node.op)} #{expr(node.rhs)})"
          when Not then "(!#{expr(node.expr)})"
          # 内側を必ず括る: 負の定数や入れ子の単項マイナスをそのまま
          # 前置すると `--x` になり、C ではデクリメント演算子として
          # 解釈されてコンパイルが落ちる (ランダム式バッテリーが検出した)。
          when Neg then "(-(#{expr(node.expr)}))"
          when Cast then "((#{C_TYPE.fetch(node.type)})#{expr(node.expr)})"
          when Select then "(#{expr(node.cond)} ? #{expr(node.then_e)} : #{expr(node.else_e)})"
          when Load then cast_out(node, "#{node.buf.name}[#{expr(node.index)}]")
          when MathOp then "#{MATH_C.fetch(node.fn)}(#{node.args.map { |a| expr(a) }.join(', ')})"
          else raise Error, "unknown expression #{node.inspect}"
          end
        end

        # f64 定数は丸め誤差ゼロの hex float リテラルで埋め込む
        # (oracle の Ruby Float とビット一致を保証する)。
        def const(node)
          case node.type
          when :f64 then float_literal(node.value)
          when :i64 then "INT64_C(#{node.value})"
          when :bool then node.value ? '1' : '0'
          end
        end

        def float_literal(value)
          return '(0.0/0.0)' if value.nan?

          case value.infinite?
          when 1 then '(1.0/0.0)'
          when -1 then '(-1.0/0.0)'
          else format('%<v>a', v: value)
          end
        end
      end
    end

    # ----------------------------------------------------------------
    # Tcc backend — 同じ発行 C を tcc で瞬間コンパイルする (~10ms、gcc の
    # 20-30 倍速いコンパイル)。生成コードの速度は gcc -O3 に劣るので、
    # 既定 chain では cc の後ろに置く。「リクエスト毎の実行時特殊化」の
    # ように往復レイテンシが利くときに MOISSANITE_BACKEND=tcc で選ぶ。
    # tcc は UB を突く最適化をしないため wrap / contract の旗は不要
    # (意味論の一致は cc と同じ差分検証バッテリーが縛る)。
    # ----------------------------------------------------------------
    module Tcc
      extend Toolchain

      def self.tag = :tcc

      def self.command(c_path, so_path)
        [compiler, '-shared', '-o', so_path, c_path, '-lm']
      end

      def self.compiler
        ENV['MOISSANITE_TCC'] || 'tcc'
      end
    end
  end
end
