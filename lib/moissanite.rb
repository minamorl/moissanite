# frozen_string_literal: true

# ==================================================================
# Moissanite — Ruby の下に敷く炭化ケイ素。
#
# native レベルのカーネルを「Ruby の値として組んだ式木」で書く。
# コンパイラ (パーサ・型推論・コード生成器の自作) は存在しない:
#   - 式木は誕生した瞬間から AST (no_opaque_thunk)
#   - 純 Ruby の oracle が意味論の正典 (常に動く)
#   - native backend は既製の処理系を FFI / ツールチェーンとして呼ぶだけ
#   - oracle と native の等価は差分検証が縛る
#
# 実行時に式木を組む = 実行時にしか判らない定数・次元を畳み込んでから
# -O3 に渡せる。AOT 言語が原理的に持てない特殊化がここに生まれる。
# ==================================================================
require_relative 'moissanite/version'
require_relative 'moissanite/expr'
require_relative 'moissanite/stmt'
require_relative 'moissanite/builder'
require_relative 'moissanite/kernel'
require_relative 'moissanite/pipeline'
require_relative 'moissanite/buffer'
require_relative 'moissanite/oracle'
require_relative 'moissanite/backend'
require_relative 'moissanite/backend/cc'
