# frozen_string_literal: true

require 'fiddle'

module Moissanite
  # ==================================================================
  # Buffer — 生メモリ上の要素列。oracle と native backend が同じ実体を共有
  # する (oracle は #[] / #[]= で境界検査つきに読み書きし、native は #ptr を
  # そのまま受け取る)。メモリは Fiddle::Pointer.malloc(RUBY_FREE) で GC に
  # 回収させる。
  #
  # 要素型は :f64 (double) と :i64 (int64_t) の 2 つ。どちらも 8 バイトだが
  # 混同は型検査で弾く (i64_buf のパラメータに f64 バッファは渡らない)。
  # ==================================================================
  class Buffer
    ELEM = 8 # sizeof(double) == sizeof(int64_t)
    PACK = { f64: 'd', i64: 'q' }.freeze
    I64_RANGE = (-(2**63))..((2**63) - 1)

    attr_reader :size, :ptr, :element_type

    def self.f64(size_or_values)
      build(:f64, size_or_values)
    end

    def self.i64(size_or_values)
      build(:i64, size_or_values)
    end

    def self.build(element_type, size_or_values)
      case size_or_values
      when Integer then new(element_type, size_or_values)
      when Array then new(element_type, size_or_values.size).write(size_or_values)
      else raise ArgumentError, "expected a size or an array, got #{size_or_values.inspect}"
      end
    end

    def initialize(element_type, size)
      raise ArgumentError, "unknown element type #{element_type.inspect}" unless PACK.key?(element_type)
      raise ArgumentError, "size must be positive, got #{size}" unless size.is_a?(Integer) && size.positive?

      @element_type = element_type
      @size = size
      @ptr = Fiddle::Pointer.malloc(size * ELEM, Fiddle::RUBY_FREE)
    end

    def [](index)
      @ptr[bound!(index) * ELEM, ELEM].unpack1(PACK.fetch(@element_type))
    end

    def []=(index, value)
      @ptr[bound!(index) * ELEM, ELEM] = [coerce(value)].pack(PACK.fetch(@element_type))
    end

    def write(values)
      raise ArgumentError, "array size #{values.size} != buffer size #{@size}" unless values.size == @size

      @ptr[0, @size * ELEM] = values.map { |value| coerce(value) }.pack("#{PACK.fetch(@element_type)}*")
      self
    end

    def to_a
      @ptr[0, @size * ELEM].unpack("#{PACK.fetch(@element_type)}*")
    end

    def fill(value)
      write(Array.new(@size, value))
    end

    def sum
      to_a.sum
    end

    # ゼロコピーの部分窓。親と同じメモリを指すので、複数スレッドが
    # 互いに素な view へ同時に書くのは安全 (native レベルで別番地)。
    # 親への参照を保持して GC から守る。
    def view(offset, size)
      unless offset.is_a?(Integer) && size.is_a?(Integer) && offset >= 0 && size.positive? && offset + size <= @size
        raise ArgumentError, "view(#{offset}, #{size}) out of bounds for size #{@size}"
      end

      window = self.class.allocate
      window.instance_variable_set(:@element_type, @element_type)
      window.instance_variable_set(:@size, size)
      window.instance_variable_set(:@ptr, Fiddle::Pointer.new(@ptr.to_i + (offset * ELEM), size * ELEM))
      window.instance_variable_set(:@base, self)
      window
    end

    private

    # 式言語側が「型混合は常に明示」を掟にしているので、バッファ書き込みも
    # 同じ厳しさにする: i64 バッファは Integer のみ受ける (Integer(1.5) は
    # 黙って 1 に切り捨てるので使わない — 丸めたいなら呼び手が明示する)。
    def coerce(value)
      return Float(value) if @element_type == :f64

      unless value.is_a?(Integer)
        raise ArgumentError, "i64 buffer takes Integer values, got #{value.class} — convert explicitly"
      end
      raise ArgumentError, "#{value} does not fit in i64" unless I64_RANGE.cover?(value)

      value
    end

    def bound!(index)
      unless index.is_a?(Integer) && index >= 0 && index < @size
        raise IndexError, "index #{index} out of bounds [0, #{@size})"
      end

      index
    end
  end
end
