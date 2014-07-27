require 'gcc/parser'
require 'gcc/compiler'

module GCC
  def self.main args
    if args.size < 1
      puts "Usage: gcc <file>"
      return 1
    end

    path = args[0]

    unless File.file? path
      puts "No such file: #{path}"
      return 1
    end

    p = GCC::Parser.new(File.read(path))
    i = GCC::Compiler.new
    i.evaluate(p.parse!)
    puts i.compile
    return 0
  end
end
