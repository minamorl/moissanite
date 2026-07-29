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

    # 外部メモリの採用。malloc せず、**他所が所有する**領域をそのまま指す
    # (numpy の ndarray、mmap、他の C ライブラリが返した領域など)。
    #
    # 所有権は移らない — 解放するのは最後まで元の持ち主の仕事である。
    # だから owner: に「その領域を生かしている Ruby オブジェクト」を渡す:
    # Buffer が生きている間 owner も GC されなくなり、native カーネルが
    # 解放済みの番地を踏む事故を塞ぐ。owner を渡さないなら、呼び手が
    # Buffer より長く領域を生かす責任を負う。
    #
    # 番地は ELEM 境界に整列していなければならない。native backend は
    # この領域を double* / int64_t* として読むので、非整列はそのまま C の
    # 未定義動作になる (アーキテクチャによっては黙って壊れる)。
    def self.wrap(pointer, size, element_type, owner: nil)
      raise ArgumentError, "unknown element type #{element_type.inspect}" unless PACK.key?(element_type)
      raise ArgumentError, "size must be positive, got #{size}" unless size.is_a?(Integer) && size.positive?

      address = pointer.to_i
      raise ArgumentError, 'refusing to wrap a NULL pointer' if address.zero?
      raise ArgumentError, "address 0x#{address.to_s(16)} is not #{ELEM}-byte aligned" unless (address % ELEM).zero?

      adopt(Fiddle::Pointer.new(address, size * ELEM), size, element_type, owner)
    end

    # 生ポインタを包んだ Buffer を組み立てる共通路。Fiddle::Pointer.new は
    # free 関数を持たないので、ここで作った Buffer は領域を決して解放しない。
    def self.adopt(ptr, size, element_type, base)
      buffer = allocate
      buffer.instance_variable_set(:@element_type, element_type)
      buffer.instance_variable_set(:@size, size)
      buffer.instance_variable_set(:@ptr, ptr)
      buffer.instance_variable_set(:@base, base)
      buffer
    end
    private_class_method :adopt

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

      self.class.send(
        :adopt, Fiddle::Pointer.new(@ptr.to_i + (offset * ELEM), size * ELEM), size, @element_type, self
      )
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
