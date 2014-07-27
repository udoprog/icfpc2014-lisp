module GCC
  class Parser
    def initialize(expression)
      @tokens = expression.scan(/[()]|[\w+-\/*<>=]+|".*?"|'.*?'/)
    end

    def parse!
      body = []

      while (result = parse next_token)
        body << result
      end

      body
    end

    private

    def next_token
      @tokens.shift
    end

    def parse token
      return nil if token.nil?
      return parse_list if token == '('
      return token.to_i if token =~ /\d+/
      token.to_sym
    end

    def parse_list
      list = []

      until (token = next_token) == ')'
        result = parse(token)
        raise "Unexpected end of stream" if result.nil?
        list << result
      end

      list
    end
  end
end
