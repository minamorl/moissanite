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
    module Cc
      C_TYPE = { f64: 'double', i64: 'int64_t', f64_buf: 'double*' }.freeze
      FIDDLE_TYPE = { f64: Fiddle::TYPE_DOUBLE, i64: Fiddle::TYPE_LONG_LONG, f64_buf: Fiddle::TYPE_VOIDP }.freeze
      CFLAGS = %w[-O3 -fPIC -shared -fwrapv -ffp-contract=off].freeze
      SYMBOL = 'moissanite_kernel'

      Compiled = Struct.new(:kernel, :fn, :handle) do
        def call(*args) = fn.call(*Arguments.validate(kernel, args, native: true))
        def backend_name = :cc
      end

      module_function

      def available?
        return @available unless @available.nil?

        @available = probe
      end

      def compile(kernel)
        emitter = new(kernel)
        so_path = ensure_compiled(emitter.source)
        handle = Fiddle.dlopen(so_path)
        fn = Fiddle::Function.new(
          handle[SYMBOL],
          kernel.param_types.map { |t| FIDDLE_TYPE.fetch(t) },
          FIDDLE_TYPE.fetch(kernel.return_type)
        )
        Compiled.new(kernel, fn, handle)
      end

      def new(kernel)
        Emitter.new(kernel)
      end

      def ensure_compiled(source)
        dir = cache_dir
        digest = Digest::SHA256.hexdigest(source)
        so_path = File.join(dir, "#{digest}.so")
        return so_path if File.exist?(so_path)

        c_path = File.join(dir, "#{digest}.c")
        File.write(c_path, source)
        run_cc(c_path, so_path)
        so_path
      end

      def run_cc(c_path, so_path)
        cmd = [compiler, *CFLAGS, '-o', so_path, c_path, '-lm']
        _out, err, status = Open3.capture3(*cmd)
        raise CompileError, "#{cmd.join(' ')}\n#{err}" unless status.success? && File.exist?(so_path)
      end

      def compiler
        ENV['MOISSANITE_CC'] || ENV['CC'] || RbConfig::CONFIG['CC'] || 'cc'
      end

      def cache_dir
        dir = ENV['MOISSANITE_CACHE_DIR'] || File.join(Dir.tmpdir, "moissanite-#{Process.uid}")
        FileUtils.mkdir_p(dir, mode: 0o700)
        dir
      end

      def probe
        src = "int #{SYMBOL}(void) { return 0; }\n"
        ensure_compiled(src)
        true
      rescue StandardError
        false
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
          abs: 'fabs', min: 'fmin', max: 'fmax'
        }.freeze

        def source
          params = @kernel.params.map { |p| "#{C_TYPE.fetch(p.type)} #{p.name}" }.join(', ')
          <<~C
            #include <stdint.h>
            #include <math.h>

            #{C_TYPE.fetch(@kernel.return_type)} #{SYMBOL}(#{params}) {
            #{block(@kernel.body, 1)}}
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
          when Store then "#{pad}#{node.buf.name}[#{expr(node.index)}] = #{expr(node.expr)};\n"
          when If then if_stmt(node, depth, pad)
          when Count then count_stmt(node, depth, pad)
          when Break then "#{pad}break;\n"
          when Ret then "#{pad}return #{expr(node.expr)};\n"
          else raise Error, "unknown statement #{node.inspect}"
          end
        end

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
          when Cast then "((#{C_TYPE.fetch(node.type)})#{expr(node.expr)})"
          when Select then "(#{expr(node.cond)} ? #{expr(node.then_e)} : #{expr(node.else_e)})"
          when Load then "#{node.buf.name}[#{expr(node.index)}]"
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
  end
end
