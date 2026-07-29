# frozen_string_literal: true

require 'fiddle'

module Moissanite
  # ==================================================================
  # Buffer — 生メモリ上の要素列。oracle と native backend が同じ実体を共有
  # する (oracle は #[] / #[]= で境界検査つきに読み書きし、native は #ptr を
  # そのまま受け取る)。メモリは Fiddle::Pointer.malloc(RUBY_FREE) で GC に
  # 回収させる。
  #
  # 要素型は :f64 (double) / :i64 (int64_t) / :u8 (uint8_t) の 3 つ。
  # f64 と i64 はどちらも 8 バイトだが混同は型検査で弾く (i64_buf の
  # パラメータに f64 バッファは渡らない)。u8 は 1 バイト幅で、バイト列
  # (ネットワーク・画像・音声) をそのまま native レベルへ渡すためにある。
  # ==================================================================
  class Buffer
    # 要素型 → 1 要素のバイト数 / pack のコード。
    BYTES = { f64: 8, i64: 8, u8: 1 }.freeze
    PACK = { f64: 'd', i64: 'q', u8: 'C' }.freeze
    I64_RANGE = (-(2**63))..((2**63) - 1)

    attr_reader :size, :ptr, :element_type

    def self.f64(size_or_values)
      build(:f64, size_or_values)
    end

    def self.i64(size_or_values)
      build(:i64, size_or_values)
    end

    def self.u8(size_or_values)
      build(:u8, size_or_values)
    end

    # バイト列から直接。HTTP のリクエストなど「すでに String で来ている
    # バイト列」を写すための入口。
    def self.bytes(string)
      new(:u8, string.bytesize).write(string.unpack('C*'))
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
    # 番地は要素幅の境界に整列していなければならない。native backend は
    # この領域を double* / int64_t* / uint8_t* として読むので、非整列は
    # そのまま C の未定義動作になる (アーキテクチャによっては黙って壊れる)。
    # u8 は幅 1 なので整列の制約は無い (検査が自明に通る)。
    def self.wrap(pointer, size, element_type, owner: nil)
      raise ArgumentError, "unknown element type #{element_type.inspect}" unless PACK.key?(element_type)
      raise ArgumentError, "size must be positive, got #{size}" unless size.is_a?(Integer) && size.positive?

      width = BYTES.fetch(element_type)
      address = pointer.to_i
      raise ArgumentError, 'refusing to wrap a NULL pointer' if address.zero?
      raise ArgumentError, "address 0x#{address.to_s(16)} is not #{width}-byte aligned" unless (address % width).zero?

      adopt(Fiddle::Pointer.new(address, size * width), size, element_type, owner)
    end

    # 生ポインタを包んだ Buffer を組み立てる共通路。Fiddle::Pointer.new は
    # free 関数を持たないので、ここで作った Buffer は領域を決して解放しない。
    def self.adopt(ptr, size, element_type, base)
      buffer = allocate
      buffer.instance_variable_set(:@element_type, element_type)
      buffer.instance_variable_set(:@size, size)
      buffer.instance_variable_set(:@bytes, BYTES.fetch(element_type))
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
      @bytes = BYTES.fetch(element_type)
      @ptr = Fiddle::Pointer.malloc(size * @bytes, Fiddle::RUBY_FREE)
    end

    def [](index)
      @ptr[bound!(index) * @bytes, @bytes].unpack1(PACK.fetch(@element_type))
    end

    def []=(index, value)
      @ptr[bound!(index) * @bytes, @bytes] = [coerce(value)].pack(PACK.fetch(@element_type))
    end

    def write(values)
      raise ArgumentError, "array size #{values.size} != buffer size #{@size}" unless values.size == @size

      @ptr[0, @size * @bytes] = values.map { |value| coerce(value) }.pack("#{PACK.fetch(@element_type)}*")
      self
    end

    def to_a
      @ptr[0, @size * @bytes].unpack("#{PACK.fetch(@element_type)}*")
    end

    # u8 バッファをバイト列として取り出す (Buffer.bytes の逆)。
    # to_s は上書きしない — 文字列補間の意味を型ごとに変えてしまうため。
    def to_bytes
      raise Error, "to_bytes is only for u8 buffers, this is #{@element_type}" unless @element_type == :u8

      @ptr[0, @size]
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
        :adopt, Fiddle::Pointer.new(@ptr.to_i + (offset * @bytes), size * @bytes), size, @element_type, self
      )
    end

    private

    # 式言語側が「型混合は常に明示」を掟にしているので、バッファ書き込みも
    # 同じ厳しさにする: i64 バッファは Integer のみ受ける (Integer(1.5) は
    # 黙って 1 に切り捨てるので使わない — 丸めたいなら呼び手が明示する)。
    def coerce(value)
      return Float(value) if @element_type == :f64

      unless value.is_a?(Integer)
        raise ArgumentError,
              "#{@element_type} buffer takes Integer values, got #{value.class} — convert explicitly"
      end
      # u8 は下位 8bit へ切り詰める。native の書き込みが (uint8_t) キャストで
      # 同じことをするので、ここで例外にすると oracle と native が食い違う。
      # i64 の overflow が wrap する掟と同じ側に倒している。
      return value & 0xFF if @element_type == :u8
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
