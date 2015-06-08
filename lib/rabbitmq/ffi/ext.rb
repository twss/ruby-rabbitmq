
module RabbitMQ
  module FFI
    
    class Timeval
      def self.from(seconds)
        obj = new
        obj[:tv_sec] = seconds.to_i
        obj[:tv_usec] = (seconds * 1_000_000).to_i
        obj
      end
      
      @zero = self.from(0)
      class << self; attr_reader :zero; end
    end
    
    class ConnectionInfo
      def to_h
        members.map { |k| [k, self[k]] }.to_h
      end
    end
    
    class Bytes
      def to_s(free=false)
        size = self[:len]
        s = size == 0 ? "" : self[:bytes].read_bytes(size)
        free! if free
        s
      end
      
      def free!
        FFI.free(self[:bytes])
        clear
      end
      
      def self.from_s(str, borrow=false)
        if borrow
          FFI.amqp_cstring_bytes(str)
        else
          size = str.bytesize
          bytes = FFI.amqp_bytes_malloc(size)
          
          bytes[:bytes].write_string(str)
          bytes[:len] = size
          bytes
        end
      end
    end
    
    class FieldValue
      private def value_member(kind)
        case kind
        when :utf8;      :bytes
        when :timestamp; :u64
        else kind
        end
      end
      
      def to_value(free=false)
        kind   = self[:kind]
        value  = self[:value][value_member(kind)]
        result = case kind
        when :bytes;     value.to_s(free)
        when :utf8;      value.to_s(free).force_encoding(Encoding::UTF_8)
        when :timestamp; Time.at(value / 1000.0)
        when :table;     value.to_h(free)
        when :array;     value.to_array_not_yet_implemented!
        when :decimal;   value.to_value_not_yet_implemented!
        else value
        end
        
        clear if free
        result
      end
      
      def free!
        kind   = self[:kind]
        value  = self[:value][value_member(kind)]
        value.free! if value.respond_to? :free!
        clear
      end
      
      def self.from(value, borrow=false)
        obj = new
        obj[:kind], obj[:value] = case value
        when String; [:bytes, FieldValueValue.new(Bytes.from_s(value, borrow).pointer)]
        else raise NotImplementedError
        end
        obj
      end
    end
    
    class Table
      include Enumerable
      
      def each(*a, &b)
        entry_ptr = self[:entries]
        entries   = self[:num_entries].times.map do |i|
          FFI::TableEntry.new(entry_ptr + i * FFI::TableEntry.size)
        end
        entries.each(*a, &b)
      end
      
      def to_h(free=false)
        result = self.map do |entry|
          [entry[:key].to_s(free), entry[:value].to_value(free)]
        end.to_h
        
        clear if free
        result
      end
      
      def free!
        self.each do
          entry[:key].free!
          entry[:value].free!
        end
        FFI.free(self[:entries])
        clear
      end
      
      def self.from(params, borrow=false)
        size      = params.size
        entry_ptr = Util.mem_ptr(size * FFI::TableEntry.size, release: false)
        params.each_with_index do |param, idx|
          entry = FFI::TableEntry.new(entry_ptr + idx * FFI::TableEntry.size)
          entry[:key]   = FFI::Bytes.from_s(param.first.to_s, borrow)
          entry[:value] = FFI::FieldValue.from(param.last, borrow)
        end
        
        obj = new
        obj[:num_entries] = size
        obj[:entries]     = entry_ptr
        obj
      end
    end
    
    class Method
      MethodClasses = FFI::MethodNumber.symbols.map do |name|
        const_name = name.to_s.gsub(/((?:\A\w)|(?:_\w))/) { |x| x[-1].upcase }
        [name, FFI.const_get(const_name)]
      end.to_h.freeze
      
      MethodNames = MethodClasses.to_a.map(&:reverse).to_h.freeze
      
      def to_h(free=false)
        { method: self[:id],
          properties: self.decoded.to_h(free) }
      end
      
      def decoded
        MethodClasses.fetch(self[:id]).new(self[:decoded])
      end
      
      def self.lookup(kls)
        MethodNames.fetch(kls)
      end
      
      def self.lookup_class(name)
        MethodClasses.fetch(name)
      end
      
      def self.from(decoded)
        obj = new
        obj[:id] = lookup(decoded.class)
        obj[:decoded] = decoded.pointer
        obj
      end
      
      def self.has_content?(type)
        case type
        when :basic_publish; true
        when :basic_return;  true
        when :basic_deliver; true
        when :basic_get_ok;  true
        else                 false
        end
      end
    end
    
    module MethodClassMixin
      def apply(borrow=false, **params)
        params.each do |key, value|
          next if key == :dummy
          case value
          when String; value = FFI::Bytes.from_s(value, borrow)
          when Hash;   value = FFI::Table.from(value, borrow)
          end
          self[key] = value
        end
        self
      end
      
      def to_h(free=false)
        result = {}
        self.members.each do |key| [key, self[key]]
          next if key == :dummy
          value = self[key]
          case value
          when FFI::Bytes; value = value.to_s(free)
          when FFI::Table; value = value.to_h(free)
          end
          result[key] = value
        end
        
        clear if free
        result
      end
      
      def free!
        self.values.each do |item|
          item.free! if item.respond_to? :free!
        end
        clear
      end
    end
    
    Method::MethodClasses.each { |_, kls| kls.send(:include, MethodClassMixin) }
    
    BasicProperties.send(:include, MethodClassMixin)
    
    class FramePayloadProperties
      def decoded
        BasicProperties.new(self[:decoded])
      end
    end
    
    class Frame
      def payload
        member = case self[:frame_type]
        when :method; :method
        when :header; :properties
        when :body;   :body_fragment
        else; raise NotImplementedError, "frame type: #{self[:frame_type]}"
        end
        self[:payload][member]
      end
      
      def as_method_to_h(free=false)
        # TODO: raise correct error class with enough info for appropriate action
        raise "Wrong frame type for method frame of event: #{self[:frame_type]}" \
          unless self[:frame_type] == :method
        
        payload.to_h(free).merge(channel: self[:channel])
      end
      
      def as_header_to_h(free=false)
        # TODO: raise correct error class with enough info for appropriate action
        raise "Wrong frame type for header frame of multiframe event: #{self[:frame_type]}" \
          unless self[:frame_type] == :header
        
        properties = self[:payload][:properties]
        { header: properties.decoded.to_h(free), body_size: properties[:body_size] }
      end
      
      def as_body_to_s(free=false)
        # TODO: raise correct error class with enough info for appropriate action
        raise "Wrong frame type for body frame of multiframe event: #{self[:frame_type]}" \
          unless self[:frame_type] == :body
        
        self[:payload][:body_fragment].to_s(free)
      end
    end
    
  end
end
