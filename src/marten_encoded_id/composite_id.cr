module MartenEncodedId
  # Builds and parses "annotated" encoded ids of the form `<annotation>_<id>`,
  # e.g. `user_p5w9-z27j`. Mirrors the Ruby gem's `AnnotatedId` /
  # `AnnotatedIdParser` pair.
  module AnnotatedId
    DEFAULT_SEPARATOR = "_"

    def self.build(prefix : String, id_part : String, separator : String = DEFAULT_SEPARATOR) : String
      raise ArgumentError.new("prefix and id are required") if prefix.empty? || id_part.empty?
      "#{parameterize(prefix)}#{separator}#{id_part}"
    end

    # Strip the annotation prefix and return the encoded-id payload.
    # If no separator is found the input is returned unchanged.
    def self.parse(input : String, separator : String = DEFAULT_SEPARATOR) : String
      return input unless input.includes?(separator)
      # Mirror Ruby: split on separator, payload is the LAST part. The
      # annotation may itself contain the separator (it's joined back in the
      # original); for parsing we only care about the last part.
      idx = input.rindex(separator)
      return input if idx.nil?
      input[(idx + separator.size)..]
    end

    # Lowercase and replace runs of non-alphanumeric chars with a hyphen.
    # Used to make the annotation URL-safe (Rails uses ActiveSupport's
    # `String#parameterize`; we ship a stripped-down version).
    def self.parameterize(s : String) : String
      out = String.build do |io|
        prev_was_dash = false
        s.each_char do |c|
          if c.ascii_alphanumeric?
            io << c.downcase
            prev_was_dash = false
          elsif !prev_was_dash
            io << '-'
            prev_was_dash = true
          end
        end
      end
      out.strip('-')
    end
  end

  # Builds and parses "slugged" encoded ids of the form `<slug>--<id>`,
  # e.g. `my-product--p5w9-z27j`. Different separator (`--`) so an annotated
  # id can sit inside the id-part without colliding.
  module SluggedId
    DEFAULT_SEPARATOR = "--"

    def self.build(slug : String, id_part : String, separator : String = DEFAULT_SEPARATOR) : String
      raise ArgumentError.new("slug and id are required") if slug.empty? || id_part.empty?
      "#{AnnotatedId.parameterize(slug)}#{separator}#{id_part}"
    end

    # If the input contains the separator, return everything after the LAST
    # occurrence. Otherwise return the input unchanged.
    def self.parse(input : String, separator : String = DEFAULT_SEPARATOR) : String
      idx = input.rindex(separator)
      return input if idx.nil?
      input[(idx + separator.size)..]
    end
  end
end
