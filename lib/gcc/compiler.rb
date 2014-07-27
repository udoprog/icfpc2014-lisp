require_relative 'built_in'
require_relative 'scope'
require_relative 'function'

module GCC
  class BuiltInContext
    attr_reader :data

    def initialize scope, parent
      @scope = scope
      @parent = parent
      @data = []
    end

    def branch expr
      @parent.compile_branch compile(expr)
    end

    def compile expr
      @parent.compile_value @scope, expr
    end

    # push a compiled expression.
    def push *expr
      expr.each do |e|
        @data += compile(e)
      end
    end

    def comment string
      @data << [:comment, string]
    end

    def instruction *args
      @data << [:instruction, args]
    end
  end

  class Branch
    attr_reader :index

    def initialize index
      @index = index
    end
  end

  class Compiler
    attr_reader :branches, :functions

    BUILTINS = {
      :+ => BuiltIn.new(2) do |args|
        push(*args)
        instruction "ADD"
      end,
      :- => BuiltIn.new(2) do |args|
        push(*args)
        instruction "SUB"
      end,
      :/ => BuiltIn.new(2) do |args|
        push(*args)
        instruction "DIV"
      end,
      :* => BuiltIn.new(2) do |args|
        push(*args)
        instruction "MUL"
      end,
      :> => BuiltIn.new(2) do |args|
        push(*args)
        instruction "CGT"
      end,
      :>= => BuiltIn.new(2) do |args|
        push(*args)
        instruction "CGTE"
      end,
      :< => BuiltIn.new(2) do |args|
        push [:not, [:>=, args[0], args[1]]]
      end,
      :<= => BuiltIn.new(2) do |args|
        push [:not, [:>, args[0], args[1]]]
      end,
      :"=" => BuiltIn.new(2) do |args|
        push(*args)
        instruction "CEQ"
      end,
      :not => BuiltIn.new(1) do |args|
        push [:"=", args[0], 0]
      end,
      :if => BuiltIn.new(3) do |args|
        push args[0]
        instruction "SEL", branch(args[1]), branch(args[2])
      end,
      :list => BuiltIn.new(nil) do |args|
        raise "list: Expected at least one argument" if args.size < 1

        args.each{|a| push a}

        # push a zero that will become part of the tail.
        push 0

        1.upto(args.size).each do |a|
          instruction "CONS"
        end
      end,
      :cons => BuiltIn.new(2) do |args|
        push args[0], args[1]
        instruction "CONS"
      end,
      :cdr => BuiltIn.new(1) do |args|
        push args[0]
        instruction "CDR"
      end,
      :car => BuiltIn.new(1) do |args|
        push args[0]
        instruction "CAR"
      end,
      :nth => BuiltIn.new(2) do |args|
        push args[0]
        1.upto(args[1]){instruction "CDR"}
        instruction "CAR"
      end,
      :or => BuiltIn.new(nil) do |args|
        expr = 0
        args.reverse.each{|arg| expr = [:if, arg, 1, expr]}
        push expr
      end,
      :and => BuiltIn.new(nil) do |args|
        expr = 1
        args.reverse.each{|arg| expr = [:if, arg, expr, 0]}
        push expr
      end,
    }

    def initialize
      @branches = []
      # store identical branches.
      @branch_cache = {}
      @functions = {}
      @let = 0
    end

    def evaluate expressions
      compile_sexpr({}, expressions)
    end

    def compile
      Compiler.compile self
    end

    def self.compile i
      functions = {}
      branches = []

      unless entry = i.functions[:main]
        raise "no entry function 'main' defined"
      end

      other = i.functions.values.delete_if{|fn| fn.name == :main}
      branch_exprs = Array[*i.branches]

      counter = 0

      entry.body.each do |type, data|
        counter += 1 if type == :instruction
      end

      other.each do |fn|
        functions[fn.name] = counter

        fn.body.each do |type, data|
          counter += 1 if type == :instruction
        end
      end

      branch_exprs.each_with_index do |expr, index|
        branches[index] = counter

        expr.each do |type, data|
          counter += 1 if type == :instruction
        end
      end

      result = []

      result << compile_body(functions, branches, entry.body)

      other.each do |fn|
        result << compile_body(functions, branches, fn.body)
      end

      branch_exprs.each do |expr|
        result << compile_body(functions, branches, expr)
      end

      result
    end

    def compile_branch expr
      e = (expr + [[:instruction, ["JOIN"]]])

      if cached = @branch_cache[e]
        return cached
      end

      index = (@branches << e).size - 1
      @branch_cache[e] = Branch.new index
    end

    def compile_defn name, args, exprs, parent=nil
      scope = Scope.new(Hash[args.each_with_index.map{|v, i| [v, i]}], parent)

      body = []
      body += compile_comment("#{name.to_s} := #{args.inspect} #{exprs.inspect}")
      body += compile_sexpr(scope, exprs)
      body += compile_i("RTN")

      @functions[name] = Function.new scope, name, args.length, body
    end

    def compile_value scope, arg
      if arg.is_a? Numeric
        return compile_i("LDC", "#{arg}")
      end

      if arg.is_a? Symbol
        if local = scope.lookup(arg)
          index, depth = local
          return compile_i("LD", "#{depth}", "#{index}", "; #{arg}")
        end

        if fn = @functions[arg]
          return compile_i("LDF", fn, "; #{arg}")
        end

        raise "no such var in scope: #{arg.inspect}"
      end

      if arg.is_a? Array
        return compile_sexpr(scope, [arg])
      end

      raise "invalid argument: #{arg.inspect}"
    end

    private

    def self.expand_value functions, branches, i
      if i.is_a? Function
        unless position = functions[i.name]
          raise "No such function: #{i}"
        end

        return position.to_s
      end

      if i.is_a? Branch
        unless position = branches[i.index]
          raise "No such branch: #{i}"
        end

        return position.to_s
      end

      unless i.is_a? String
        raise "INTERNAL: got unexpected non-string component: #{i.inspect}"
      end

      i
    end

    # Expand a single instruction, replacing functions with their functions
    # position.
    def self.expand functions, branches, instruction
      "  " + instruction.map{|i| expand_value(functions, branches, i)}.join(" ")
    end

    def self.compile_body functions, branches, body
      result = []

      body.each do |type, data|
        if type == :instruction
          result << self.expand(functions, branches, data)
          next
        end

        if type == :comment
          result << "; #{data}"
          next
        end
      end

      result
    end

    def compile_i *instruction
      [[:instruction, instruction]]
    end

    def compile_comment string
      [[:comment, string.to_s]]
    end

    def compile_values scope, array
      result = []

      array.each do |arg|
        result += compile_value scope, arg
      end

      result
    end

    def compile_let scope, bindings, exprs
      name = "__let#{@let += 1}".to_sym
      raise "let: bindings must be even" unless bindings.size.even?

      args = bindings.values_at(*bindings.each_index.select{|i| i.even?})
      values = bindings.values_at(*bindings.each_index.select{|i| i.odd?})

      compile_defn(name, args, exprs, scope)

      compile_call scope, name, values
    end

    def compile_call scope, symbol, args
      # special built-in function 'defn'.
      if symbol == :defn
        compile_defn(args[0], args[1], args[2..args.size])
        return []
      end

      # special built-in function 'let'.
      # This will generate an anonymous function with the form __let#n and
      # replace the current block with a block dedicated to invoking that.
      if symbol == :let
        return compile_let(scope, args[0], args[1..args.size])
      end

      if builtin = BUILTINS[symbol]
        if builtin.arity and builtin.arity != args.length
          raise "#{symbol.to_s}: built-in function expected #{builtin.arity} arguments but got #{args.size}"
        end

        c = BuiltInContext.new scope, self
        c.instance_exec(args, &builtin.block)
        return c.data
      end

      if fn = @functions[symbol]
        if fn.arity != args.length
          raise "#{fn.name}: defined function expected #{fn.arity} arguments but got #{args.size}"
        end

        body = []
        body += compile_values(scope, args)
        body += compile_i("LDF", fn)
        body += compile_i("AP", "#{args.length}", "; #{symbol.to_s}")
        return body
      end

      raise "no such var or built-in: #{symbol.inspect}"
    end

    def compile_sexpr scope, exprs
      body = []

      exprs.each do |expr|
        if expr.is_a? Array
          symbol = expr[0]
          args = expr[1 .. expr.length]
          body += compile_call scope, symbol, args
          next
        end

        body += compile_value scope, expr
      end

      return body
    end
  end
end
