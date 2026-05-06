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
  class Configuration
    # The base salt. Combined with the model class name to produce a
    # per-class salt so two models can encode the same numeric id without
    # collision. Required if any model uses the no-coder form of `.use`.
    property salt : String? = nil

    property encoder : Symbol = :hashids
    property alphabet : ::EncodedId::Alphabet = ::EncodedId::Alphabet.modified_crockford
    property min_length : Int32 = 8
    property max_length : Int32? = 128
    property max_inputs_per_id : Int32 = 32
    property hex_digit_encoding_group_size : Int32 = 4
    property character_group_size : Int32? = 4
    property group_separator : String = "-"

    property blocklist : ::EncodedId::Blocklist = ::EncodedId::Blocklist.empty
    property blocklist_mode : ::EncodedId::Encoders::BlocklistMode = ::EncodedId::Encoders::BlocklistMode::LengthThreshold
    property blocklist_max_length : Int32 = 32

    # Per-model defaults the macro reads at code-gen time
    property prefix_method_name : String? = "annotation_for_encoded_id"
    property slug_value_method_name : String? = "name_for_encoded_id_slug"
    property slugged_id_separator : String = "--"
    property annotated_id_separator : String = "_"

    def derive_salt(class_name : String) : String
      base = salt
      raise ::EncodedId::SaltError.new(
        "Configure MartenEncodedId.config.salt before using a model that doesn't pass an explicit `coder:`"
      ) if base.nil? || base.empty?
      "#{class_name}/#{base}"
    end

    # Build a fresh `ReversibleId` for a particular model class. Called by
    # the `.use` macro the first time `encoded_id_coder` is accessed.
    def build_coder(class_name : String) : ::EncodedId::ReversibleId
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
  end

  # The shared singleton.
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
