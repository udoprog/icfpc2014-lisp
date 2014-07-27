module GCC
  class BuiltIn
    attr_reader :arity, :block

    def initialize arity, &block
      @arity = arity
      @block = block
    end
  end
end
