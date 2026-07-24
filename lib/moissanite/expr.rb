# frozen_string_literal: true

module Moissanite
  class Error < StandardError; end
  class TypeMismatch < Error; end
  class BuildError < Error; end

  # ==================================================================
  # 式 — 不透明なサンクではなく、検査可能な不変データ。
  #
  # moissanite の最上位の掟: カーネルは「Ruby 構文をコンパイルしたもの」
  # ではなく「Ruby の値として組んだ式木」である。だからコンパイラ
  # (パーサ・型推論) は存在せず、式木は誕生した瞬間から AST である。
  #
  # 型は 3 つだけ: :f64 (IEEE754 double) / :i64 (64bit 二の補数, wrap) /
  # :bool。バッファは :f64_buf (生メモリ上の double 列)。
  # ==================================================================
  SCALAR_TYPES = %i[f64 i64 bool].freeze
  PARAM_TYPES = %i[f64 i64 f64_buf i64_buf].freeze
  # バッファ型 → 要素のスカラ型。バッファはこの表にあるものが全て。
  BUFFER_ELEMENT = { f64_buf: :f64, i64_buf: :i64 }.freeze

  # 演算子オーバーロードの共有実装。全ノードが include する。
  module Ops
    ARITH = %i[+ - * /].freeze
    COMPARE = { :< => :lt, :<= => :le, :> => :gt, :>= => :ge }.freeze

    ARITH.each do |op|
      define_method(op) { |other| Expr.arith(op, self, other) }
    end

    def %(other)
      Expr.arith(:%, self, other)
    end

    COMPARE.each do |op, name|
      define_method(op) { |other| Expr.compare(name, self, other) }
    end

    def eq(other)
      Expr.compare(:eq, self, other)
    end

    def ne(other)
      Expr.compare(:ne, self, other)
    end

    def &(other)
      Expr.bool_op(:and, self, other)
    end

    def |(other)
      Expr.bool_op(:or, self, other)
    end

    def not
      Expr.bool_not(self)
    end

    # 単項マイナス。0 - x では代用できない: f64 では -(0.0) は -0.0 だが
    # 0.0 - 0.0 は +0.0 になる。専用ノードで C の -x にそのまま写す。
    def -@
      Expr.negate(self)
    end

    def to_f64
      Expr.cast(:f64, self)
    end

    def to_i64
      Expr.cast(:i64, self)
    end

    # libm 系 (f64 のみ)。oracle も backend も同じ libm を呼ぶので
    # ビット一致が保たれる (負数 sqrt/log は C 準拠で NaN)。
    %i[sqrt sin cos exp log].each do |fn|
      define_method(fn) { Expr.math1(fn, self) }
    end

    def abs
      Expr.math1(:abs, self)
    end

    def min(other)
      Expr.math2(:min, self, other)
    end

    def max(other)
      Expr.math2(:max, self, other)
    end

    # 2.0 * expr のような「Ruby リテラルが左」の式を成立させる。
    # Ruby の coerce プロトコルで [リテラルの持ち上げ, self] を返す。
    def coerce(other)
      [Expr.lift(other, type), self]
    end
  end

  Const = Data.define(:type, :value) do
    include Ops

    def to_sexp = [:const, type, value]
  end

  Param = Data.define(:type, :name, :index) do
    include Ops

    # バッファパラメータの読み出し: buf[i] は Load 式 (純データ) になる。
    # 型は要素型 (f64_buf なら :f64、i64_buf なら :i64)。
    def [](index)
      element = BUFFER_ELEMENT[type]
      raise TypeMismatch, "#{name} is not a buffer" unless element

      Load.new(type: element, buf: self, index: Expr.lift_to_i64(index))
    end

    def to_sexp = [:param, type, name]
  end

  Local = Data.define(:type, :name, :id) do
    include Ops

    def to_sexp = [:local, type, name]
  end

  BinOp = Data.define(:type, :op, :lhs, :rhs) do
    include Ops

    def to_sexp = [op, lhs.to_sexp, rhs.to_sexp]
  end

  Not = Data.define(:type, :expr) do
    include Ops

    def to_sexp = [:not, expr.to_sexp]
  end

  Neg = Data.define(:type, :expr) do
    include Ops

    def to_sexp = [:neg, expr.to_sexp]
  end

  Cast = Data.define(:type, :expr) do
    include Ops

    def to_sexp = [:cast, type, expr.to_sexp]
  end

  Select = Data.define(:type, :cond, :then_e, :else_e) do
    include Ops

    def to_sexp = [:select, cond.to_sexp, then_e.to_sexp, else_e.to_sexp]
  end

  Load = Data.define(:type, :buf, :index) do
    include Ops

    def to_sexp = [:load, buf.to_sexp, index.to_sexp]
  end

  MathOp = Data.define(:type, :fn, :args) do
    include Ops

    def to_sexp = [fn, *args.map(&:to_sexp)]
  end

  # 式の構築規則 (型付け) を一箇所に集める。
  module Expr
    module_function

    # Ruby リテラルを目標型の Const へ持ち上げる。損失を伴う持ち上げは拒む。
    def lift(value, target_type)
      case [value, target_type]
      in [Integer, :i64]
        range_check_i64(value)
        Const.new(type: :i64, value: value)
      in [Integer, :f64]
        raise TypeMismatch, "integer #{value} is not exactly representable as f64" unless value == value.to_f.to_i

        Const.new(type: :f64, value: value.to_f)
      in [Float, :f64]
        Const.new(type: :f64, value: value)
      in [true | false, :bool]
        Const.new(type: :bool, value: value)
      else
        raise TypeMismatch, "cannot lift #{value.inspect} to #{target_type}"
      end
    end

    # 型注釈なしのリテラル: Integer は i64、Float は f64。
    def lift_any(value)
      case value
      when Integer then lift(value, :i64)
      when Float then lift(value, :f64)
      when true, false then lift(value, :bool)
      else
        raise TypeMismatch, "expected an expression or literal, got #{value.inspect}" unless node?(value)

        value
      end
    end

    def lift_to_i64(value)
      e = lift_any(value)
      raise TypeMismatch, "index must be i64, got #{e.type}" unless e.type == :i64

      e
    end

    def node?(value)
      case value
      when Const, Param, Local, BinOp, Not, Neg, Cast, Select, Load, MathOp then true
      else false
      end
    end

    def negate(operand)
      expr = lift_any(operand)
      raise TypeMismatch, "cannot negate #{expr.type}" unless %i[f64 i64].include?(expr.type)

      Neg.new(type: expr.type, expr: expr)
    end

    # 単項 libm (f64 のみ)。
    def math1(fn, operand)
      e = lift_any(operand)
      raise TypeMismatch, "#{fn} is defined on f64 only, got #{e.type}" unless e.type == :f64

      MathOp.new(type: :f64, fn: fn, args: [e].freeze)
    end

    # 二項 libm (fmin / fmax 意味論: 片方が NaN ならもう片方を返す)。
    def math2(fn, lhs, rhs)
      l, r = unify(lhs, rhs)
      raise TypeMismatch, "#{fn} is defined on f64 only, got #{l.type}" unless l.type == :f64

      MathOp.new(type: :f64, fn: fn, args: [l, r].freeze)
    end

    # 二項算術: 両辺を同じ数値型に揃える (リテラルは相手の型へ持ち上げ)。
    def arith(op, lhs, rhs)
      l, r = unify(lhs, rhs)
      raise TypeMismatch, "#{op} needs f64/i64 operands, got #{l.type}" unless %i[f64 i64].include?(l.type)
      raise TypeMismatch, '% is defined on i64 only' if op == :% && l.type != :i64

      BinOp.new(type: l.type, op: op, lhs: l, rhs: r)
    end

    def compare(op, lhs, rhs)
      l, r = unify(lhs, rhs)
      raise TypeMismatch, "#{op} needs f64/i64 operands, got #{l.type}" unless %i[f64 i64].include?(l.type)

      BinOp.new(type: :bool, op: op, lhs: l, rhs: r)
    end

    # bool 論理は短絡 (oracle も backend も同じ意味論)。
    def bool_op(op, lhs, rhs)
      l = lift_any(lhs)
      r = lift_any(rhs)
      raise TypeMismatch, "#{op} needs bool operands" unless l.type == :bool && r.type == :bool

      BinOp.new(type: :bool, op: op, lhs: l, rhs: r)
    end

    def bool_not(expr)
      e = lift_any(expr)
      raise TypeMismatch, 'not needs a bool operand' unless e.type == :bool

      Not.new(type: :bool, expr: e)
    end

    def cast(target, expr)
      e = lift_any(expr)
      raise TypeMismatch, "cast to #{target} from #{e.type} is not defined" unless %i[f64 i64].include?(e.type)

      e.type == target ? e : Cast.new(type: target, expr: e)
    end

    def select(cond, then_e, else_e)
      c = lift_any(cond)
      raise TypeMismatch, 'select condition must be bool' unless c.type == :bool

      t, e = unify(then_e, else_e)
      Select.new(type: t.type, cond: c, then_e: t, else_e: e)
    end

    # 片方が式・片方がリテラルなら式の型へ持ち上げる。式同士は同型を要求
    # (暗黙変換はしない。混ぜたいときは .to_f64 / .to_i64 を明示する)。
    def unify(lhs, rhs)
      if node?(lhs) && !node?(rhs)
        [lhs, lift(rhs, lhs.type)]
      elsif !node?(lhs) && node?(rhs)
        [lift(lhs, rhs.type), rhs]
      else
        l = lift_any(lhs)
        r = lift_any(rhs)
        raise TypeMismatch, "operand types differ: #{l.type} vs #{r.type} (use .to_f64 / .to_i64)" if l.type != r.type

        [l, r]
      end
    end

    def range_check_i64(value)
      raise TypeMismatch, "#{value} does not fit in i64" if value >= (1 << 63) || value < -(1 << 63)
    end
  end
end
