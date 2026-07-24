# frozen_string_literal: true

module Moissanite
  # ==================================================================
  # Builder — kernel 本体を組む文脈 (Moissanite.kernel のブロックに渡る k)。
  #
  # ここは「コンパイラのフロントエンド」ではない。ただの Ruby メソッド
  # 呼び出しで文のリストを積む工場である。Ruby の制御構文 (each / times /
  # 条件分岐) は自由に使ってよく、それらは実行されず「式木を編む
  # メタプログラム」として働く — 実行時特殊化はこの性質から生まれる。
  # ==================================================================
  class Builder
    attr_reader :statements

    def initialize
      @statements = []
      @stack = [@statements]
      @local_id = 0
    end

    # 局所変数を宣言して初期化する。型は初期値の型。
    def let(init, name: nil)
      expr = Expr.lift_any(init)
      local = Local.new(type: expr.type, name: (name || "v#{@local_id}").to_sym, id: @local_id)
      @local_id += 1
      emit Let.new(local: local, expr: expr)
      local
    end

    def assign(local, value)
      raise BuildError, 'assign target must be a local (from k.let)' unless local.is_a?(Local)

      expr = Expr.lift_any(value)
      raise TypeMismatch, "cannot assign #{expr.type} to #{local.type} local" unless expr.type == local.type

      emit Assign.new(local: local, expr: expr)
    end

    def store(buf, index, value)
      element = BUFFER_ELEMENT[buf.type] if buf.is_a?(Param)
      raise TypeMismatch, 'store target must be a buffer param' unless element

      # リテラルはバッファの要素型へ持ち上げる (式なら型が一致していること)。
      expr = Expr.node?(value) ? value : Expr.lift(value, element)
      raise TypeMismatch, "cannot store #{expr.type} into #{buf.type}" unless expr.type == element

      emit Store.new(buf: buf, index: Expr.lift_to_i64(index), expr: expr)
    end

    # 0..limit-1 の i64 ループ。ブロックにループ変数 (i64) を渡す。
    def count(limit, &block)
      raise BuildError, 'count requires a block' unless block

      var = Local.new(type: :i64, name: :"i#{@local_id}", id: @local_id)
      @local_id += 1
      body = nest { block.call(var) }
      emit Count.new(var: var, limit: Expr.lift_to_i64(limit), body: body)
    end

    def break_if(cond)
      emit If.new(cond: bool!(cond), then_stmts: [Break.new], else_stmts: [])
    end

    def if_(cond, &block)
      raise BuildError, 'if_ requires a block' unless block

      emit If.new(cond: bool!(cond), then_stmts: nest(&block), else_stmts: [])
    end

    def if_else(cond, then_proc, else_proc)
      emit If.new(cond: bool!(cond), then_stmts: nest(&then_proc), else_stmts: nest(&else_proc))
    end

    def select(cond, then_e, else_e)
      Expr.select(cond, then_e, else_e)
    end

    def ret(value)
      emit Ret.new(expr: Expr.lift_any(value))
    end

    def ret_if(cond, value)
      emit If.new(cond: bool!(cond), then_stmts: [Ret.new(expr: Expr.lift_any(value))], else_stmts: [])
    end

    private

    def emit(stmt)
      @stack.last << stmt
      nil
    end

    def nest
      @stack.push([])
      yield
      @stack.pop
    end

    def bool!(cond)
      expr = Expr.lift_any(cond)
      raise TypeMismatch, "condition must be bool, got #{expr.type}" unless expr.type == :bool

      expr
    end
  end
end
