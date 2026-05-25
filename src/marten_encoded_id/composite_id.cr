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

    # M7 — structural well-formedness for an annotated or bare encoded-id
    # string. Returns `true` for inputs that can plausibly be `parse`d
    # into a non-empty payload AND aren't obviously malformed at the
    # boundaries; `false` for inputs that start/end with a separator-ish
    # character (the leading or trailing `_`/`-`/`--` are all signs of
    # truncation, double-build, or attacker-controlled noise).
    #
    # Examples:
    # - `AnnotatedId.valid?("widget_abcd")` → `true`
    # - `AnnotatedId.valid?("widget-abcd")` → `true` (bare encoded-id; no annotation)
    # - `AnnotatedId.valid?("--foo")` → `false` (leading separator-ish)
    # - `AnnotatedId.valid?("foo--")` → `false` (trailing separator-ish)
    # - `AnnotatedId.valid?("foo_")` → `false` (trailing annotation separator)
    # - `AnnotatedId.valid?("")` → `false`
    #
    # Used by `MartenEncodedId::Routing::Parameter#loads` to refuse
    # patently malformed URL segments before they reach
    # `decode_encoded_id` (which would itself sanitize to `[]`, but
    # `valid?` is the earlier and clearer signal).
    def self.valid?(s : String, separator : String = DEFAULT_SEPARATOR) : Bool
      return false if s.empty?
      first = s[0]
      last = s[-1]
      return false if first == '_' || first == '-'
      return false if last == '_' || last == '-'
      # If the multi-char separator appears, the payload (everything
      # after the last occurrence) must be non-empty — the boundary
      # checks above cover the single-char `"_"` case but custom
      # multi-char separators need this explicit guard.
      idx = s.rindex(separator)
      unless idx.nil?
        return false if (idx + separator.size) >= s.size
      end
      true
    end

    # Lowercase and replace runs of non-alphanumeric chars with a hyphen.
    # Used to make the annotation URL-safe (Rails uses ActiveSupport's
    # `String#parameterize`; we ship a stripped-down version).
    def self.parameterize(s : String) : String
      out = String.build do |io|
        prev_was_dash = false
        s.each_char do |char|
          if char.ascii_alphanumeric?
            io << char.downcase
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
    #
    # L9 — "input doesn't contain the separator" returns the input verbatim
    # by design. `parse` is also called as a "strip-if-present" idiom by
    # `decode_encoded_id` (which chains `SluggedId.parse` → `AnnotatedId.parse`
    # → `coder.decode`): a bare annotated id `widget_abc` has no `--`, so
    # it must pass through unchanged for the annotated parse pass to do its
    # job. Structural validity is the caller's problem; gate untrusted
    # input through `SluggedId.valid?` (M7) before invoking `parse`.
    def self.parse(input : String, separator : String = DEFAULT_SEPARATOR) : String
      idx = input.rindex(separator)
      return input if idx.nil?
      input[(idx + separator.size)..]
    end

    # M7 — strict slugged-form validator. Returns `true` iff the input
    # actually carries the slugged separator with non-empty slug and
    # id parts. Unlike `AnnotatedId.valid?`, a bare encoded id (no
    # `--`) is NOT considered a valid slugged id — the whole point of
    # the slugged form is the slug.
    #
    # Examples:
    # - `SluggedId.valid?("acme-product--abcd")` → `true`
    # - `SluggedId.valid?("just-text")` → `false` (no separator)
    # - `SluggedId.valid?("--abcd")` → `false` (empty slug)
    # - `SluggedId.valid?("acme--")` → `false` (empty id)
    def self.valid?(s : String, separator : String = DEFAULT_SEPARATOR) : Bool
      return false if s.empty?
      idx = s.index(separator)
      return false if idx.nil?
      return false if idx == 0                         # leading separator → empty slug
      return false if (idx + separator.size) >= s.size # trailing separator → empty id
      true
    end
  end
end
