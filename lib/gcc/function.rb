module GCC
  class Function
    attr_reader :scope, :name, :arity, :body

    def initialize scope, name, arity, body
      @name = name
      @arity = arity
      @body = body
    end
  end
end
