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

  # --- 畳み込み (map-reduce の融合) ------------------------------------

  def test_fused_sum_matches_oracle_and_ruby
    xs = buffer([0.0, 1.0, 4.0, -1.0, 2.25])
    kernel = sample_pipeline.sum
    expected = xs.to_a.sum { |v| (((v * 2.0) + 1.0).abs**0.5) * SCALE }

    assert_in_delta expected, kernel.call(xs, 5), 1e-12
    assert_equal kernel.interpret(xs, 5), kernel.call(xs, 5)
  end

  # 融合した map-reduce は中間バッファに一切触れない。段別 (map してから
  # sum) と添字順の累積が同じなので、浮動小数でもビット一致する。
  def test_fused_reduce_matches_map_then_reduce
    xs = buffer(Array.new(500) { |i| (((i * 7) % 101) / 13.0) - 3.0 })
    fused = sample_pipeline.sum(:fused_sum).call(xs, 500)

    mapped = Moissanite::Buffer.f64(500)
    sample_pipeline.fuse(:mapper).call(mapped, xs, 500)
    staged = Moissanite::Pipeline.f64.sum(:plain_sum).call(mapped, 500)

    assert_equal staged, fused
  end

  def test_reduce_with_custom_combiner
    xs = buffer([-5.0, 2.0, 9.5, -0.5])
    kernel = Moissanite::Pipeline.f64.map(&:abs).reduce(0.0, :peak) { |acc, v| acc.max(v) }

    assert_in_delta 9.5, kernel.call(xs, 4)
    assert_equal kernel.interpret(xs, 4), kernel.call(xs, 4)
  end

  def test_two_input_reduce_is_a_dot_product
    xs = buffer([1.0, 2.0, 3.0])
    ys = buffer([4.0, 5.0, 6.0])
    kernel = Moissanite::Pipeline.f64(arity: 2).map { |a, b| a * b }.sum(:dot)

    assert_in_delta 32.0, kernel.call(xs, ys, 3)
    assert_equal kernel.interpret(xs, ys, 3), kernel.call(xs, ys, 3)
  end

  # 段が無くても 1 入力なら素の総和として意味が通る。
  def test_reduce_without_stages_is_a_plain_sum
    xs = buffer([1.5, -2.5, 4.0])

    assert_in_delta 3.0, Moissanite::Pipeline.f64.sum.call(xs, 3)
  end

  def test_reduce_without_stages_rejects_two_inputs
    assert_raises(Moissanite::BuildError) { Moissanite::Pipeline.f64(arity: 2).sum }
  end

  def test_reduce_requires_a_block
    assert_raises(ArgumentError) { Moissanite::Pipeline.f64.reduce(0.0) }
  end

  # --- 要素型 (入力は宣言、出力は段から推論) ---------------------------

  def test_result_type_is_inferred_from_the_stages
    assert_equal :f64, Moissanite::Pipeline.f64.result_type
    assert_equal :i64, Moissanite::Pipeline.i64.result_type
    assert_equal :i64, Moissanite::Pipeline.f64.map(&:to_i64).result_type
    assert_equal :f64, Moissanite::Pipeline.i64.map(&:to_f64).map { |v| v * 0.5 }.result_type
  end

  def test_f64_input_with_i64_output_classifier
    pipeline = Moissanite::Pipeline.f64.map { |v| Moissanite::Expr.select(v > 1.0, 1, 0) }
    kernel = pipeline.fuse(:classify)
    xs = buffer([0.5, 2.0, 1.5, -3.0])
    out = Moissanite::Buffer.i64(4)
    oracle = Moissanite::Buffer.i64(4)
    kernel.call(out, xs, 4)
    kernel.interpret(oracle, xs, 4)

    assert_equal :i64_buf, kernel.params.first.type
    assert_equal [0, 1, 1, 0], out.to_a
    assert_equal oracle.to_a, out.to_a
    # 数える畳み込みは i64 累積器になる (sum が結果型に追随する)。
    assert_equal 2, pipeline.sum(:hits).call(xs, 4)
  end

  def test_i64_pipeline_end_to_end
    pipeline = Moissanite::Pipeline.i64.map { |v| (v * 3) - 1 }
    ints = Moissanite::Buffer.i64([1, 2, 3])
    out = Moissanite::Buffer.i64(3)
    pipeline.fuse(:tripler).call(out, ints, 3)

    assert_equal [2, 5, 8], out.to_a
    assert_equal 15, pipeline.sum(:isum).call(ints, 3)
  end

  def test_stage_kernels_track_changing_element_types
    pipeline = Moissanite::Pipeline.f64.map(&:to_i64).map { |v| v * 2 }
    types = pipeline.stage_kernels(:mixed).map { |kernel| kernel.params.map(&:type) }

    assert_equal [%i[i64_buf f64_buf i64], %i[i64_buf i64_buf i64]], types
  end

  def test_bad_element_type_is_rejected
    assert_raises(ArgumentError) { Moissanite::Pipeline.of(:bool) }
    assert_raises(ArgumentError) { Moissanite::Pipeline.of(:f32) }
  end
end
