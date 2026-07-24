# frozen_string_literal: true

require 'minitest/autorun'
require 'moissanite'

# Pipeline の契約: 融合 (1 パス) と段別実行 (N パス) は同じ数学であり、
# 結果はビット単位で一致しなければならない。融合はメモリ往復を減らす
# 最適化であって、意味論の変更ではない。
class PipelineTest < Minitest::Test
  SCALE = 0.375

  def sample_pipeline
    Moissanite::Pipeline.f64
                        .map { |v| (v * 2.0) + 1.0 }
                        .map { |v| v.abs.sqrt }
                        .map { |v| v * SCALE }
  end

  def buffer(values)
    Moissanite::Buffer.f64(values)
  end

  # 段別実行: 段ごとにバッファを往復する (AOT ライブラリを段ごとに
  # 呼ぶ形と同じ)。ping-pong で入出力を入れ替える。
  def run_staged(pipeline, inputs, size, native:)
    front = Moissanite::Buffer.f64(size)
    back = Moissanite::Buffer.f64(size)
    pipeline.stage_kernels.each_with_index do |kernel, index|
      args = index.zero? ? inputs : [front]
      native ? kernel.call(back, *args, size) : kernel.interpret(back, *args, size)
      front, back = back, front
    end
    front
  end

  def test_fused_matches_staged_bit_for_bit
    xs = buffer([-4.0, 0.0, 1.5, 9.0, 100.25])
    fused_out = Moissanite::Buffer.f64(5)
    sample_pipeline.fuse.call(fused_out, xs, 5)

    assert_equal run_staged(sample_pipeline, [xs], 5, native: true).to_a, fused_out.to_a
  end

  def test_fused_matches_oracle
    xs = buffer([-4.0, 0.0, 1.5, 9.0, 100.25])
    kernel = sample_pipeline.fuse
    native_out = Moissanite::Buffer.f64(5)
    oracle_out = Moissanite::Buffer.f64(5)
    kernel.interpret(oracle_out, xs, 5)
    kernel.call(native_out, xs, 5)

    assert_equal oracle_out.to_a, native_out.to_a
  end

  def test_staged_matches_oracle
    xs = buffer([2.0, -3.0, 0.5])
    native = run_staged(sample_pipeline, [xs], 3, native: true)
    oracle = run_staged(sample_pipeline, [xs], 3, native: false)

    assert_equal oracle.to_a, native.to_a
  end

  def test_two_input_pipeline_zips_then_transforms
    pipeline = Moissanite::Pipeline.f64(arity: 2)
                                   .map { |a, b| (a * b) + 1.0 }
                                   .map { |v| v.abs.sqrt }
    xs = buffer([1.0, 2.0, 3.0])
    ys = buffer([4.0, -5.0, 6.0])
    out = Moissanite::Buffer.f64(3)
    oracle_out = Moissanite::Buffer.f64(3)
    kernel = pipeline.fuse(:zipped)
    kernel.call(out, xs, ys, 3)
    kernel.interpret(oracle_out, xs, ys, 3)

    assert_equal [Math.sqrt(5.0), Math.sqrt(9.0), Math.sqrt(19.0)], out.to_a
    assert_equal oracle_out.to_a, out.to_a
  end

  # 段が入力を複数回参照しても、let 束縛のおかげで式木は線形に留まる
  # (素朴に代入すると段数に対して指数的に膨らむ)。
  def test_repeated_input_reference_does_not_explode_the_tree
    pipeline = (1..12).reduce(Moissanite::Pipeline.f64) do |acc, _|
      acc.map { |v| (v * v) + v }
    end
    source = pipeline.fuse(:squares).source_c

    assert_operator source.length, :<, 4_000, 'fused source grew super-linearly'
    assert_equal 12, pipeline.size
  end

  def test_long_pipeline_stays_equivalent
    pipeline = (1..20).reduce(Moissanite::Pipeline.f64) do |acc, i|
      acc.map { |v| (v * (1.0 + (i / 100.0))) - 0.5 }
    end
    xs = buffer([0.25, -1.0, 3.5])
    fused = Moissanite::Buffer.f64(3)
    pipeline.fuse(:long).call(fused, xs, 3)

    assert_equal run_staged(pipeline, [xs], 3, native: true).to_a, fused.to_a
  end

  def test_empty_pipeline_is_rejected
    assert_raises(Moissanite::BuildError) { Moissanite::Pipeline.f64.fuse }
  end

  def test_invalid_arity_is_rejected
    assert_raises(ArgumentError) { Moissanite::Pipeline.f64(arity: 3) }
    assert_raises(ArgumentError) { Moissanite::Pipeline.f64.map }
  end
end
