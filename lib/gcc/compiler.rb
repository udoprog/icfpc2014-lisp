require_relative 'built_in'
require_relative 'scope'
require_relative 'function'
require_relative 'entry'

module GCC
  class BuiltInContext
    attr_reader :data

    def initialize scope, parent
      @scope = scope
      @parent = parent
      @data = []
    end

    def branch expr
      @parent.add_branch expr
    end

    def compile expr
      @parent.compile_value @scope, expr
    end

    # push a compiled expression.
    def push expr
      @data += compile(expr)
    end

    def comment string
      @data << [:comment, string]
    end

    def instruction *args
      @data << [:instruction, args]
    end
  end

  class Compiler
    attr_reader :branches, :functions, :entry

    BUILTINS = {
      :+ => BuiltIn.new(2) do |c, args|
        c.push args[0]
        c.push args[1]
        c.instruction "ADD"
      end,
      :- => BuiltIn.new(2) do |c, args|
        c.push args[0]
        c.push args[1]
        c.instruction "SUB"
      end,
      :/ => BuiltIn.new(2) do |c, args|
        c.push args[0]
        c.push args[1]
        c.instruction "DIV"
      end,
      :* => BuiltIn.new(2) do |c, args|
        c.push args[0]
        c.push args[1]
        c.instruction "MUL"
      end,
      :> => BuiltIn.new(2) do |c, args|
        c.push args[0]
        c.push args[1]
        c.instruction "CGT"
      end,
      :>= => BuiltIn.new(2) do |c, args|
        c.push args[0]
        c.push args[1]
        c.instruction "CGTE"
      end,
      :< => BuiltIn.new(2) do |c, args|
        c.push args[0]
        c.push args[1]
        c.instruction "CGTE"
        c.instruction "LDC", "0"
        c.instruction "CEQ"
      end,
      :<= => BuiltIn.new(2) do |c, args|
        c.push args[0]
        c.push args[1]
        c.instruction "CGT"
        c.instruction "LDC", "0"
        c.instruction "CEQ"
      end,
      :if => BuiltIn.new(3) do |c, args|
        true_branch = c.branch c.compile(args[1])
        false_branch = c.branch c.compile(args[2])
        c.push args[0]
        c.instruction "SEL", true_branch, false_branch
      end,
      :join => BuiltIn.new(0) do |c, args|
        c.instruction "JOIN"
      end,
    }

    def initialize
      @entry = nil
      @branches = []
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
      counter = 0

      symbols = {}
      branches = []

      functions = Array[*i.functions]
      branch_exprs = Array[*i.branches]
      entry = i.entry

      entry.body.each do |type, data|
        counter += 1 if type == :instruction
      end

      functions.each do |key, fn|
        symbols[key] = counter

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

      result << compile_body(symbols, branches, entry.body)

      functions.each do |key, fn|
        result << compile_body(symbols, branches, fn.body)
      end

      branch_exprs.each do |expr|
        result << compile_body(symbols, branches, expr)
      end

      result
    end

    def add_branch expr
      (@branches << (expr + [[:instruction, ["JOIN"]]])).size - 1
    end

    def compile_value scope, arg
      if arg.is_a? Numeric
        return compile_instruction(["LDC", "#{arg}"])
      end

      if arg.is_a? Symbol
        index, depth = scope.lookup(arg)
        return compile_instruction(["LD", "#{depth}", "#{index}", "; #{arg}"])
      end

      if arg.is_a? Array
        return compile_sexpr(scope, [arg])
      end

      raise "invalid argument: #{arg.inspect}"
    end

    private

    # Expand a single instruction, replacing symbols with their functions
    # position.
    def self.expand symbols, branches, instruction
      "  " + instruction.map{|value|
        if value.is_a? Symbol
          raise "No such function: #{value}" unless position = symbols[value]
          position.to_s
        elsif value.is_a? Numeric
          branches[value].to_s
        else
          value
        end
      }.join(" ")
    end

    def self.compile_body symbols, branches, body
      result = []

      body.each do |type, data|
        if type == :instruction
          result << self.expand(symbols, branches, data)
          next
        end

        if type == :comment
          result << "; #{data}"
          next
        end
      end

      result
    end

    def compile_defn name, args, exprs, parent=nil
      scope = Scope.new(Hash[args.each_with_index.map{|v, i| [v, i]}], parent)

      body = []
      body += compile_comment("#{name.to_s} := #{args.inspect} #{exprs.inspect}")
      body += compile_sexpr(scope, exprs)
      body += compile_instruction(["RTN"])

      @functions[name] = Function.new scope, name, args.length, body

      []
    end

    def compile_defentry args, exprs
      scope = Scope.new(Hash[args.each_with_index.map{|v, i| [v, i]}])

      body = []
      body += compile_comment("entry := #{args.inspect} #{exprs.inspect}")
      body += compile_sexpr(scope, exprs)
      body += compile_instruction(["RTN"])

      @entry = Entry.new args.size, body

      []
    end

    def compile_comment string
      [[:comment, string.to_s]]
    end

    def compile_instruction *instructions
      instructions.map do |instruction|
        [:instruction, instruction]
      end
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

      if bindings.size % 2 != 0
        raise "let: bindings must be even"
      end

      args = bindings.values_at(*bindings.each_index.select{|i| i.even?})
      values = bindings.values_at(*bindings.each_index.select{|i| i.odd?})

      compile_defn(name, args, exprs, scope)

      compile_call scope, name, values
    end

    def compile_call scope, cdr, args
      # special built-in function 'defn'.
      if cdr == :defn
        return compile_defn(args[0], args[1], args[2..args.size])
      end

      # special built-in function 'defentry'.
      if cdr == :defentry
        return compile_defentry(args[0], args[1..args.size])
      end

      # special built-in function 'let'.
      # This will generate an anonymous function with the form __let#n and
      # replace the current block with a block dedicated to invoking that.
      if cdr == :let
        return compile_let(scope, args[0], args[1..args.size])
      end

      if builtin = BUILTINS[cdr]
        if builtin.arity != args.length
          raise "Function '#{cdr.to_s}' expected #{builtin.arity} arguments but got #{args.size}"
        end

        c = BuiltInContext.new scope, self
        builtin.block.call c, args
        return c.data
      end

      if fn = @functions[cdr]
        if fn.arity != args.length
          raise "Function '#{fn.name}' expected #{fn.arity} arguments but got #{args.size}"
        end

        body = compile_values(scope, args)

        return body + compile_instruction(
          ["LDF", cdr],
          ["AP", "#{args.length}", "; #{cdr.to_s}"]
        )
      end

      raise "no such var or built-in: #{cdr.inspect}"
    end

    def compile_sexpr scope, exprs
      body = []

      exprs.each do |expr|
        if expr.is_a? Array
          cdr = expr[0]
          args = expr[1 .. expr.length]
          body += compile_call scope, cdr, args
          next
        end

        body += compile_value scope, expr
      end

      return body
    end
  end
end
