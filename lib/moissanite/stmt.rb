# frozen_string_literal: true

module Moissanite
  # ==================================================================
  # 文 — 構造化された制御だけを持つ (goto なし)。
  #   Let    : 局所変数の宣言 + 初期化 (型は初期値から決まる)
  #   Assign : 局所変数への再代入 (同型のみ)
  #   Store  : buf[index] = value (f64)
  #   If     : 条件分岐 (else は空でもよい)
  #   Count  : 0 から limit-1 までの i64 カウントループ。limit は入口で一度
  #            だけ評価する (本体内の変更はループ回数に影響しない)
  #   Break  : 最内 Count からの脱出
  #   Ret    : カーネルからの返却
  # ==================================================================
  Let = Data.define(:local, :expr) do
    def to_sexp = [:let, local.to_sexp, expr.to_sexp]
  end

  Assign = Data.define(:local, :expr) do
    def to_sexp = [:assign, local.to_sexp, expr.to_sexp]
  end

  Store = Data.define(:buf, :index, :expr) do
    def to_sexp = [:store, buf.to_sexp, index.to_sexp, expr.to_sexp]
  end

  If = Data.define(:cond, :then_stmts, :else_stmts) do
    def to_sexp = [:if, cond.to_sexp, then_stmts.map(&:to_sexp), else_stmts.map(&:to_sexp)]
  end

  Count = Data.define(:var, :limit, :body) do
    def to_sexp = [:count, var.to_sexp, limit.to_sexp, body.map(&:to_sexp)]
  end

  Break = Data.define do
    def to_sexp = [:break]
  end

  Ret = Data.define(:expr) do
    def to_sexp = [:ret, expr.to_sexp]
  end
end
