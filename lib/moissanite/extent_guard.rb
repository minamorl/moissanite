# frozen_string_literal: true

module Moissanite
  # ==================================================================
  # ExtentGuard — 「単純な要素ごと形」の静的解析。
  #
  # native は生ポインタを受け取って走るので、要素数がバッファ長を超えると
  # *黙ってヒープを壊す*。これは機能の欠落ではなく欠陥なので、条件を証明
  # できる形については走らせる前に潰す。
  #
  # 判定: 本体に count ループがちょうど 1 本あり、その上限が :i64 の
  # パラメータで、全てのバッファ添字がそのループ変数そのものであること。
  # このとき安全条件は「n <= 各バッファの要素数」に尽きる。
  #
  # 当てはまらない形 (stride 添字・入れ子ループ・計算された offset) では
  # nil を返し、**何も主張しない**。守れない約束をするより沈黙が正しい。
  # そうした kernel は開発中 oracle (interpret) で添字ごとに検査する。
  # ==================================================================
  module ExtentGuard
    Guard = Data.define(:count_index, :buffer_indices)

    module_function

    def analyze(body)
      loops = body.grep(Count)
      return nil unless loops.size == 1

      limit = loops.first.limit
      return nil unless limit.is_a?(Param) && limit.type == :i64

      # 本体全体を見る: ループ外のバッファ参照はループ変数と一致しないので
      # そこで自動的に失格になる。
      accesses = accesses_in(body)
      return nil if accesses.empty? || !all_indexed_by?(accesses, loops.first.var)

      Guard.new(count_index: limit.index, buffer_indices: accesses.map { |(buf, _)| buf.index }.uniq)
    end

    def all_indexed_by?(accesses, var)
      accesses.all? { |(_buf, index)| index.is_a?(Local) && index.id == var.id }
    end

    # --- 走査: [バッファ Param, 添字 Expr] を集める ------------------
    def accesses_in(stmts)
      stmts.flat_map { |stmt| in_statement(stmt) }
    end

    def in_statement(stmt)
      case stmt
      when Let, Assign, Ret then in_expr(stmt.expr)
      when Store then [[stmt.buf, stmt.index], *in_expr(stmt.index), *in_expr(stmt.expr)]
      when If then in_expr(stmt.cond) + accesses_in(stmt.then_stmts) + accesses_in(stmt.else_stmts)
      when Count then in_expr(stmt.limit) + accesses_in(stmt.body)
      else []
      end
    end

    def in_expr(expr)
      case expr
      when Load then [[expr.buf, expr.index], *in_expr(expr.index)]
      when BinOp then in_expr(expr.lhs) + in_expr(expr.rhs)
      when Not, Cast then in_expr(expr.expr)
      when Select then in_expr(expr.cond) + in_expr(expr.then_e) + in_expr(expr.else_e)
      when MathOp then expr.args.flat_map { |arg| in_expr(arg) }
      else []
      end
    end
  end
end
