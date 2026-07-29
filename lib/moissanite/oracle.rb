# frozen_string_literal: true

module Moissanite
  class MathError < Error; end

  # ==================================================================
  # Oracle — 純 Ruby インタプリタ。moissanite の意味論の正典。
  #
  # backend が何を出力しようと、正しさの定義は常に「oracle と同じ値を
  # 返すこと」である (差分検証がこれを縛る)。だからここは速度を一切
  # 追わず、意味論を最も素直に書く。
  #
  # 意味論の芯 (native C と一致させるための決め事):
  #   - i64 は 64bit 二の補数で wrap する (Ruby の Integer は無限精度
  #     なので、演算ごとに明示的に畳む)
  #   - i64 の除算は 0 方向へ切り捨て (C 準拠。Ruby の floor 除算ではない)。
  #     剰余は a == (a/b)*b + a%b を満たす (符号は被除数に従う)
  #   - i64 の 0 除算は MathError (native では未定義動作なので呼ぶ前に
  #     防ぐのが呼び手の契約。oracle は必ず検出する)
  #   - f64 は IEEE754 (Ruby Float そのもの)。0 除算は ±Inf / NaN
  #   - bool の & | は短絡する
  #   - f64 → i64 の cast は 0 方向へ切り捨て。i64 で表せない値 (NaN /
  #     ±Inf / 範囲外) は oracle では MathError、native では未定義動作
  # ==================================================================
  class Oracle
    I64_MIN = -(1 << 63)
    I64_MAX = (1 << 63) - 1
    U64 = 1 << 64

    def initialize(kernel)
      @kernel = kernel
    end

    def call(*args)
      @args = Arguments.validate(@kernel, args, native: false)
      @env = {}
      catch(:moissanite_ret) do
        exec_block(@kernel.body)
        raise Error, 'kernel fell off the end without ret (validated at build; this is a bug)'
      end
    end

    def backend_name = :oracle

    private

    def exec_block(stmts)
      stmts.each { |s| exec(s) }
    end

    def exec(stmt)
      case stmt
      when Let, Assign then @env[stmt.local.id] = eval_expr(stmt.expr)
      when Store then exec_store(stmt)
      when If then exec_block(eval_expr(stmt.cond) ? stmt.then_stmts : stmt.else_stmts)
      when Count then exec_count(stmt)
      when Break then throw :moissanite_break
      when Ret then throw :moissanite_ret, eval_expr(stmt.expr)
      else raise Error, "unknown statement #{stmt.inspect}"
      end
    end

    def exec_store(stmt)
      @args[stmt.buf.index][eval_expr(stmt.index)] = eval_expr(stmt.expr)
    end

    # limit は入口で一度だけ評価する (Count の意味論)。
    def exec_count(stmt)
      limit = eval_expr(stmt.limit)
      catch(:moissanite_break) do
        i = 0
        while i < limit
          @env[stmt.var.id] = i
          exec_block(stmt.body)
          i += 1
        end
      end
    end

    def eval_expr(expr)
      case expr
      when Const then expr.value
      when Param then @args[expr.index]
      when Local then @env.fetch(expr.id)
      when BinOp then eval_binop(expr)
      when Not then !eval_expr(expr.expr)
      when Neg then negate(expr)
      when Cast then eval_cast(expr)
      when Select then eval_expr(expr.cond) ? eval_expr(expr.then_e) : eval_expr(expr.else_e)
      when Load then @args[expr.buf.index][eval_expr(expr.index)]
      when MathOp then eval_math(expr)
      else raise Error, "unknown expression #{expr.inspect}"
      end
    end

    # libm と同じ意味論 (負域は C 準拠で NaN、fmin/fmax は NaN を避ける)。
    # Ruby の Math.* も同じ libm を呼ぶのでビットまで一致する。
    def eval_math(expr)
      values = expr.args.map { |a| eval_expr(a) }
      case expr.fn
      when :sqrt then values[0].negative? ? Float::NAN : Math.sqrt(values[0])
      when :log then values[0].negative? ? Float::NAN : Math.log(values[0])
      when :sin then Math.sin(values[0])
      when :cos then Math.cos(values[0])
      when :exp then Math.exp(values[0])
      when :abs then values[0].abs
      when :min then math_minmax(values[0], values[1]) { |a, b| [a, b].min }
      when :max then math_minmax(values[0], values[1]) { |a, b| [a, b].max }
      else raise Error, "unknown math fn #{expr.fn}"
      end
    end

    # i64 の単項マイナスは wrap する (-I64_MIN は表現できない)。
    def negate(expr)
      arith(expr.type, -eval_expr(expr.expr))
    end

    def math_minmax(first, second)
      return second if first.nan?
      return first if second.nan?

      yield(first, second)
    end

    def eval_binop(expr)
      return eval_short_circuit(expr) if %i[and or].include?(expr.op)

      l = eval_expr(expr.lhs)
      r = eval_expr(expr.rhs)
      case expr.op
      when :+, :-, :* then arith(expr.lhs.type, l.public_send(expr.op, r))
      when :/ then divide(expr.lhs.type, l, r)
      when :% then i64_mod(l, r)
      when :lt then l < r
      when :le then l <= r
      when :gt then l > r
      when :ge then l >= r
      when :eq then l == r
      when :ne then l != r
      else raise Error, "unknown op #{expr.op}"
      end
    end

    def eval_short_circuit(expr)
      case expr.op
      when :and then eval_expr(expr.lhs) && eval_expr(expr.rhs)
      when :or then eval_expr(expr.lhs) || eval_expr(expr.rhs)
      end
    end

    def arith(type, value)
      type == :i64 ? wrap_i64(value) : value
    end

    def divide(type, dividend, divisor)
      return dividend / divisor if type == :f64
      raise MathError, 'i64 division by zero' if divisor.zero?

      wrap_i64(trunc_div(dividend, divisor))
    end

    def i64_mod(dividend, divisor)
      raise MathError, 'i64 modulo by zero' if divisor.zero?

      wrap_i64(dividend - (trunc_div(dividend, divisor) * divisor))
    end

    # C 準拠: 0 方向への切り捨て除算。
    def trunc_div(dividend, divisor)
      q = dividend.abs / divisor.abs
      dividend.negative? == divisor.negative? ? q : -q
    end

    def wrap_i64(value)
      ((value & (U64 - 1)) ^ (1 << 63)) - (1 << 63)
    end

    def eval_cast(expr)
      v = eval_expr(expr.expr)
      return v.to_f if expr.type == :f64

      raise MathError, "cannot cast #{v} to i64" unless v.finite? && v >= I64_MIN && v <= I64_MAX

      v.truncate
    end
  end

  # 引数の検証と変換。oracle と native backend が共有する安全境界。
  module Arguments
    module_function

    def validate(kernel, args, native:)
      expected = kernel.params
      unless args.size == expected.size
        raise ArgumentError,
              "#{kernel.name}: expected #{expected.size} args, got #{args.size}"
      end

      converted = expected.zip(args).map { |param, arg| convert(kernel, param, arg, native) }
      enforce_extent(kernel, args, converted)
      converted
    end

    # 単純な要素ごと形の kernel については、走らせる前に
    # 「n <= 各バッファの要素数」を確かめる (Kernel#extent_guard 参照)。
    # native は生ポインタを信じて走るので、この検査だけが黙ったヒープ
    # 破壊とエラーを分ける。oracle 側でも同じ検査をして挙動を揃える。
    def enforce_extent(kernel, args, converted)
      guard = kernel.extent_guard
      return unless guard

      count = converted[guard.count_index]
      guard.buffer_indices.each do |index|
        buffer = args[index]
        next unless buffer.is_a?(Buffer) && count > buffer.size

        raise ArgumentError,
              "#{kernel.name}: n=#{count} exceeds #{kernel.params[index].name} " \
              "(#{buffer.size} elements) — the kernel would read or write out of bounds"
      end
    end

    def convert(kernel, param, arg, native)
      case param.type
      when :f64 then Float(arg)
      when :i64 then convert_i64(kernel, param, arg)
      when :f64_buf, :i64_buf, :u8_buf then convert_buf(kernel, param, arg, native)
      end
    end

    def convert_i64(kernel, param, arg)
      value = Integer(arg)
      unless value.between?(Oracle::I64_MIN, Oracle::I64_MAX)
        raise ArgumentError, "#{kernel.name}.#{param.name}: #{value} does not fit in i64"
      end

      value
    end

    def convert_buf(kernel, param, arg, native)
      unless arg.is_a?(Buffer)
        raise ArgumentError,
              "#{kernel.name}.#{param.name}: expected Moissanite::Buffer, got #{arg.class}"
      end

      # 要素型の取り違えは native では黙って読み替えになる (f64/i64 はどちらも
      # 8 バイト、u8 は幅そのものが違う) ので、入口で必ず弾く。式の型ではなく
      # 記憶域の型で照合する — u8_buf は :i64 として読めるが渡すのは :u8 バッファ。
      expected = BUFFER_STORAGE.fetch(param.type)
      unless arg.element_type == expected
        raise ArgumentError,
              "#{kernel.name}.#{param.name}: expected a #{expected} buffer, got #{arg.element_type}"
      end

      native ? arg.ptr : arg
    end
  end
end
