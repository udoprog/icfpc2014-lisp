module GCC
  class Scope
    attr_reader :parent

    def initialize scope, parent=nil
      @parent = parent
      @scope = scope
    end

    def lookup key, i=0
      if value = @scope[key]
        return value, i
      end

      return nil unless @parent
      @parent.lookup key, i+1
    end
  end
end
