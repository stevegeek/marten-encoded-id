module MartenEncodedId
  # Application-wide defaults, reachable via `MartenEncodedId.configure`.
  # Mirrors the Ruby gem's `EncodedId::Rails::Configuration` so a model
  # written without explicit options uses these defaults plus a salt
  # derived from the class name (so two models with the same numeric pk
  # don't produce the same encoded id).
  #
  # Typical setup in `config/initializers/encoded_id.cr`:
  #
  #     MartenEncodedId.configure do |c|
  #       c.salt           = ENV["ENCODED_ID_SALT"]
  #       c.encoder        = :hashids
  #       c.min_length     = 8
  #       c.character_group_size = 4
  #       c.group_separator      = "-"
  #     end
  #
  # ## Unified `min_length` (M6)
  #
  # The upstream encoders disagree on the property name for "minimum
  # encoded length": Hashids calls it `min_hash_length`, Sqids calls it
  # `min_length`. We always expose it here as `min_length` and the shard
  # adapts the name when building the underlying coder:
  #
  # - `encoder = :hashids` — `min_length` is forwarded as `min_hash_length`.
  # - `encoder = :sqids`   — `min_length` is forwarded as `min_length`.
  #
  # Per-model explicit coders constructed with `EncodedId::ReversibleId.hashid(...)`
  # / `EncodedId::ReversibleId.sqids(...)` retain their original parameter
  # name — the unification only applies to the high-level shard config.
  class Configuration
    # The base salt. Combined with the model class name to produce a
    # per-class salt so two models can encode the same numeric id without
    # collision. Required if any model uses the no-coder form of `.use`.
    #
    # L10 — setter rejects an empty string at set-time so a `c.salt = ""`
    # typo fails immediately rather than at the first coder-build call.
    # `nil` is still allowed (the "unset" state); only the empty-string
    # case is treated as a misconfiguration.
    @salt : String? = nil

    def salt : String?
      @salt
    end

    # Setter-time validation is defense-in-depth; `derive_salt` re-checks at
    # build time. Catching the bug here surfaces the misconfiguration at the
    # moment the bad value is assigned (during boot, in an initializer),
    # before any model is loaded and tries to build its coder.
    def salt=(value : String?)
      if value.is_a?(String) && value.empty?
        raise ::EncodedId::InvalidConfigurationError.new(
          "MartenEncodedId.config.salt must be non-empty (got \"\"); pass `nil` to clear or a non-empty string."
        )
      end
      @salt = value
    end

    property encoder : Symbol = :hashids
    property alphabet : ::EncodedId::Alphabet = ::EncodedId::Alphabet.modified_crockford

    # L10 — `min_length` must be non-negative; the encoders treat a
    # negative value as "no minimum" in some configurations and crash in
    # others. Reject at set-time so the failure mode is local.
    @min_length : Int32 = 8

    def min_length : Int32
      @min_length
    end

    def min_length=(value : Int32)
      if value < 0
        raise ::EncodedId::InvalidConfigurationError.new(
          "MartenEncodedId.config.min_length must be >= 0 (got #{value})."
        )
      end
      @min_length = value
    end

    property max_length : Int32? = 128
    property max_inputs_per_id : Int32 = 32
    property hex_digit_encoding_group_size : Int32 = 4
    property character_group_size : Int32? = 4
    property group_separator : String = "-"

    property blocklist : ::EncodedId::Blocklist = ::EncodedId::Blocklist.empty
    property blocklist_mode : ::EncodedId::Encoders::BlocklistMode = ::EncodedId::Encoders::BlocklistMode::LengthThreshold
    property blocklist_max_length : Int32 = 32

    # L11 — `prefix_method_name` / `slug_value_method_name` were left over
    # from the early port of the Ruby `encoded_id-rails` gem (which auto-
    # discovers per-model annotation/slug methods at runtime). The Crystal
    # port takes those as explicit `prefix:` / `slug_method:` macro args
    # instead, so the config-level fallbacks were never read. Removed
    # (YAGNI). If per-config defaults become useful later, add them back
    # wired into the macro.
    property slugged_id_separator : String = "--"
    property annotated_id_separator : String = "_"

    def derive_salt(class_name : String) : String
      base = salt
      raise ::EncodedId::SaltError.new(
        "Configure MartenEncodedId.config.salt before using a model that doesn't pass an explicit `coder:`"
      ) if base.nil? || base.empty?
      # M1: NUL is the paranoid delimiter. Crystal class names can't contain
      # `/`, but they also can't contain `\x00`, and the latter is impossible
      # to inject via any user-controllable identifier source. This keeps
      # the per-class salt derivation collision-proof even if a future
      # refactor passes something other than a literal class name here.
      "#{class_name}\x00#{base}"
    end

    # Build a fresh `ReversibleId` for a particular model class. Called by
    # the `.use` macro the first time `encoded_id_coder` is accessed.
    def build_coder(class_name : String) : ::EncodedId::ReversibleId
      validate_separators!
      derived_salt = derive_salt(class_name)
      case encoder
      when :hashids
        ::EncodedId::ReversibleId.hashid(
          salt: derived_salt,
          alphabet: alphabet,
          min_hash_length: min_length,
          blocklist: blocklist,
          blocklist_mode: blocklist_mode,
          blocklist_max_length: blocklist_max_length,
          split_at: character_group_size,
          split_with: group_separator,
          max_inputs_per_id: max_inputs_per_id,
          max_length: max_length,
          hex_digit_encoding_group_size: hex_digit_encoding_group_size,
        )
      when :sqids
        ::EncodedId::ReversibleId.sqids(
          alphabet: alphabet,
          min_length: min_length,
          blocklist: blocklist.to_a,
          split_at: character_group_size,
          split_with: group_separator,
          max_inputs_per_id: max_inputs_per_id,
          max_length: max_length,
          hex_digit_encoding_group_size: hex_digit_encoding_group_size,
        )
      else
        raise ::EncodedId::InvalidConfigurationError.new(
          "Unknown encoder: #{encoder}. Use :hashids or :sqids."
        )
      end
    end

    # Guard against H4-class separator collisions. `AnnotatedId.parse` and
    # `SluggedId.parse` find their separator in the encoded payload by
    # searching for the configured separator string; if the same separator
    # is also used as the encoder's `group_separator`, the parser
    # silently truncates a legitimate payload. Reject the dangerous
    # configurations up front at coder-build time.
    private def validate_separators!
      gs = group_separator
      ans = annotated_id_separator
      ss = slugged_id_separator

      if gs == ans
        raise ::EncodedId::InvalidConfigurationError.new(
          "group_separator (#{gs.inspect}) must differ from annotated_id_separator " \
          "(#{ans.inspect}); otherwise encoded payloads containing the group separator " \
          "are silently truncated by AnnotatedId.parse."
        )
      end

      if gs == ss
        raise ::EncodedId::InvalidConfigurationError.new(
          "group_separator (#{gs.inspect}) must differ from slugged_id_separator " \
          "(#{ss.inspect}); otherwise slugged encoded payloads are silently truncated " \
          "by SluggedId.parse."
        )
      end

      # The annotated and slugged separators must differ — they're used
      # by different parse passes but their search-string is the only
      # signal, so identical values would collide.
      if ans == ss
        raise ::EncodedId::InvalidConfigurationError.new(
          "annotated_id_separator (#{ans.inspect}) must differ from slugged_id_separator " \
          "(#{ss.inspect})."
        )
      end

      if ans.empty? || ss.empty? || gs.empty?
        raise ::EncodedId::InvalidConfigurationError.new(
          "annotated_id_separator, slugged_id_separator, and group_separator must all be non-empty."
        )
      end
    end
  end

  # L6 — module-level `@@config` (singleton). A class with `self.config`
  # readers would read more idiomatically, but the public API
  # (`MartenEncodedId.configure { |c| ... }` / `MartenEncodedId.config`)
  # is the Rails-style block-form mutator that callers expect from a
  # framework-integration shard; threading that through a separate
  # `Configuration::Singleton` class buys nothing here. Test isolation
  # uses `MartenEncodedId.config=` to swap the whole object in one go
  # (see specs that rescue/restore around config-mutating examples).
  @@config : Configuration = Configuration.new

  def self.config : Configuration
    @@config
  end

  # Block-form mutator: `MartenEncodedId.configure { |c| c.salt = "..." }`
  def self.configure(&)
    yield @@config
  end

  # For test isolation — replace the entire config object in one go.
  def self.config=(value : Configuration)
    @@config = value
  end
end
