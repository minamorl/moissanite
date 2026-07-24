# frozen_string_literal: true

require 'fiddle'

module Moissanite
  # ==================================================================
  # Buffer — f64 の生メモリ列。oracle と native backend が同じ実体を共有する
  # (oracle は #[] / #[]= で境界検査つきに読み書きし、native は #ptr を渡す)。
  # メモリは Fiddle::Pointer.malloc(RUBY_FREE) で GC に回収させる。
  # ==================================================================
  class Buffer
    ELEM = 8 # sizeof(double)

    attr_reader :size, :ptr

    def self.f64(size_or_array)
      case size_or_array
      when Integer then new(size_or_array)
      when Array then new(size_or_array.size).write(size_or_array)
      else raise ArgumentError, "expected size or array, got #{size_or_array.inspect}"
      end
    end

    def initialize(size)
      raise ArgumentError, "size must be positive, got #{size}" unless size.is_a?(Integer) && size.positive?

      @size = size
      @ptr = Fiddle::Pointer.malloc(size * ELEM, Fiddle::RUBY_FREE)
    end

    def [](index)
      @ptr[bound!(index) * ELEM, ELEM].unpack1('d')
    end

    def []=(index, value)
      @ptr[bound!(index) * ELEM, ELEM] = [Float(value)].pack('d')
    end

    def write(array)
      raise ArgumentError, "array size #{array.size} != buffer size #{@size}" unless array.size == @size

      @ptr[0, @size * ELEM] = array.pack('d*')
      self
    end

    def to_a
      @ptr[0, @size * ELEM].unpack('d*')
    end

    def fill(value)
      write(Array.new(@size, Float(value)))
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
      window.instance_variable_set(:@size, size)
      window.instance_variable_set(:@ptr, Fiddle::Pointer.new(@ptr.to_i + (offset * ELEM), size * ELEM))
      window.instance_variable_set(:@base, self)
      window
    end

    private

    def bound!(index)
      unless index.is_a?(Integer) && index >= 0 && index < @size
        raise IndexError,
              "index #{index} out of bounds [0, #{@size})"
      end

      index
    end
  end
end
