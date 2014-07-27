module GCC
  class Entry
    attr_reader :arity, :body

    def initialize arity, body
      @arity = arity
      @body = body
    end
  end
end
