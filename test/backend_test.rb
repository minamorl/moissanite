# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'moissanite'

# backend の運用上の契約: fallback 鎖、コンテンツアドレスされたキャッシュ、
# そして **同じ式木を同時にコンパイルしても壊れないこと**。
# fork するアプリサーバや並列テストでは同時コンパイルが普通に起きるので、
# 共有パスへの書き込みが不可分でなければ「書きかけの .so を dlopen」する。
class BackendTest < Minitest::Test
  def setup
    skip 'no working C toolchain' unless Moissanite::Backend::Cc.available?
    @cache = Dir.mktmpdir('moissanite-test-')
    @previous = ENV.fetch('MOISSANITE_CACHE_DIR', nil)
    ENV['MOISSANITE_CACHE_DIR'] = @cache
  end

  def teardown
    ENV['MOISSANITE_CACHE_DIR'] = @previous
    FileUtils.remove_entry(@cache) if @cache && File.directory?(@cache)
  end

  def kernel_for(seed)
    Moissanite.kernel(:"cached#{seed}", x: :f64) { |k, x| k.ret((x * seed) + 0.25) }
  end

  def test_artifacts_are_content_addressed_and_reused
    first = Moissanite::Backend::Cc.compile(kernel_for(3))
    objects = Dir.glob(File.join(@cache, '*.so'))
    second = Moissanite::Backend::Cc.compile(kernel_for(3))

    assert_in_delta 6.25, first.call(2.0)
    assert_in_delta 6.25, second.call(2.0)
    assert_equal objects, Dir.glob(File.join(@cache, '*.so')), 'the same tree compiled twice'
  end

  def test_each_toolchain_gets_its_own_artifact
    skip 'tcc not installed' unless Moissanite::Backend::Tcc.available?

    Moissanite::Backend::Cc.compile(kernel_for(5))
    Moissanite::Backend::Tcc.compile(kernel_for(5))
    tags = Dir.glob(File.join(@cache, '*.so')).map { |path| File.basename(path)[/-(\w+)\.so\z/, 1] }

    assert_includes tags, 'cc'
    assert_includes tags, 'tcc'
  end

  def test_tcc_declares_a_non_executable_stack_on_linux
    skip 'ELF stack declaration is Linux-specific' unless RUBY_PLATFORM.include?('linux')
    skip 'tcc not installed' unless Moissanite::Backend::Tcc.available?

    compiled = Moissanite::Backend::Tcc.compile(kernel_for(11))

    assert_equal :tcc, compiled.backend_name
    assert_in_delta 22.25, compiled.call(2.0)

    elf = File.binread(Dir.glob(File.join(@cache, '*-tcc.so')).fetch(0))

    assert_equal "\x7fELF", elf[0, 4]
    assert_equal 0, elf_stack_flags(elf) & 1, 'PF_X must not be set on PT_GNU_STACK'
    assert_empty leftovers
  end

  def elf_stack_flags(elf)
    byte_order = { 1 => '<', 2 => '>' }.fetch(elf.getbyte(5))
    offset_at, size_at, flags_at, word = { 1 => [28, 42, 24, 'L'], 2 => [32, 54, 4, 'Q'] }.fetch(elf.getbyte(4))
    offset = elf[offset_at..].unpack1("#{word}#{byte_order}")
    size, count = elf[size_at, 4].unpack("S#{byte_order}S#{byte_order}")
    headers = count.times.map { |i| elf[offset + (i * size), size] }
    stack = headers.find { |header| header[0, 4].unpack1("L#{byte_order}") == 0x6474e551 }

    refute_nil stack, 'PT_GNU_STACK is required; a missing header can imply an executable stack'
    stack[flags_at, 4].unpack1("L#{byte_order}")
  end

  def test_concurrent_threads_compiling_the_same_tree
    results = Array.new(8)
    Array.new(8) { |i| Thread.new { results[i] = Moissanite::Backend::Cc.compile(kernel_for(7)).call(2.0) } }
         .each(&:join)

    assert_equal [14.25] * 8, results
    assert_empty leftovers, 'temporary build artifacts were left behind'
  end

  def test_concurrent_processes_compiling_the_same_tree
    skip 'fork unavailable' unless Process.respond_to?(:fork)

    readers = Array.new(6) do
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        writer.write(Moissanite::Backend::Cc.compile(kernel_for(9)).call(2.0).to_s)
        writer.close
        exit!(0)
      end
      writer.close
      [pid, reader]
    end
    values = readers.map { |pid, reader| [Process.waitpid2(pid), reader.read].last.tap { reader.close } }

    assert_equal ['18.25'] * 6, values
    assert_empty leftovers, 'temporary build artifacts were left behind'
  end

  # 完成品 (.so / .c) 以外が残っていないこと。中断された書き込みが
  # 共有パスに見えてはならない。
  def leftovers
    Dir.glob(File.join(@cache, '*')).grep_v(%r{-(cc|tcc)\.so\z|\A.*/\h{64}\.c\z})
  end
end
