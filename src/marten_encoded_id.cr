require "encoded_id_cr"
require "marten"

require "./marten_encoded_id/composite_id"
require "./marten_encoded_id/configuration"

# Wires `encoded_id` semantics from the Ruby `encoded_id-rails` gem onto
# Marten models: encode/decode class methods, finder methods that hide the
# underlying integer primary key, and instance methods that return the
# (optionally annotated, optionally slugged) encoded id for use as a URL
# parameter.
#
# Two usage forms — explicit coder, or "use the global config":
#
#     # Explicit coder (no global config needed):
#     class Item < Marten::Model
#       field :id, :big_int, primary_key: true, auto: true
#       field :name, :string
#
#       MartenEncodedId.use(
#         coder: EncodedId::ReversibleId.hashid(salt: "item-salt", min_hash_length: 8),
#         prefix: "item",
#       )
#     end
#
#     # Or — set up once globally, models are terse:
#     MartenEncodedId.configure do |c|
#       c.salt = ENV["ENCODED_ID_SALT"]
#       c.min_length = 8
#     end
#
#     class Product < Marten::Model
#       ...
#       MartenEncodedId.use(prefix: "product", slug_method: name)
#     end
module MartenEncodedId
  VERSION = "0.1.0"

  # `coder`        — ReversibleId expression. Optional; falls back to the
  #                  global Configuration with a per-class derived salt.
  # `prefix`       — Annotation prefix (e.g. "item"). Optional.
  #                  When set, encoded_id returns "<prefix>_<hash>".
  # `slug_method`  — Method name (bare identifier) to call for the slug
  #                  text. When set, slugged_encoded_id is emitted and
  #                  returns "<slug>--<encoded_id>".
  macro use(coder = nil, prefix = nil, slug_method = nil)
    @@_encoded_id_coder : ::EncodedId::ReversibleId? = nil

    def self.encoded_id_coder : ::EncodedId::ReversibleId
      @@_encoded_id_coder ||= (
        {% if coder %}
          ({{ coder }})
        {% else %}
          ::MartenEncodedId.config.build_coder({{ @type.name.stringify }})
        {% end %}
      )
    end

    def self.encoded_id_prefix : String?
      {% if prefix %}({{ prefix }}){% else %}nil{% end %}
    end

    # ------- Class methods -------

    def self.encode_encoded_id(id : Int) : String
      encoded_id_coder.encode(id.to_i64)
    end

    def self.encode_encoded_id(ids : Array(T)) : String forall T
      encoded_id_coder.encode(ids.map(&.to_i64))
    end

    # Decode a possibly-prefixed, possibly-slugged id back to its integer
    # array. Returns [] (rather than raising) on garbage input — finder
    # methods then translate that to nil/RecordNotFound as appropriate.
    def self.decode_encoded_id(input : String) : Array(Int64)
      payload = ::MartenEncodedId::SluggedId.parse(input)
      payload = ::MartenEncodedId::AnnotatedId.parse(payload)
      encoded_id_coder.decode(payload)
    rescue ::EncodedId::EncodedIdFormatError
      [] of ::Int64
    end

    def self.find_by_encoded_id(input : String)
      ids = decode_encoded_id(input)
      return nil if ids.empty?
      get(pk: ids.first)
    end

    def self.find_by_encoded_id!(input : String)
      ids = decode_encoded_id(input)
      raise ::Marten::DB::Errors::RecordNotFound.new("not found for encoded id: #{input}") if ids.empty?
      get!(pk: ids.first)
    end

    def self.find_all_by_encoded_id(input : String)
      ids = decode_encoded_id(input)
      return [] of self if ids.empty?
      filter(pk__in: ids).to_a
    end

    # ------- Instance methods -------

    def encoded_id_hash : ::String?
      pk_v = pk
      return nil if pk_v.nil?
      self.class.encode_encoded_id(pk_v.as(::Int64))
    end

    def encoded_id : ::String?
      h = encoded_id_hash
      return nil if h.nil?
      a = self.class.encoded_id_prefix
      a.nil? ? h : ::MartenEncodedId::AnnotatedId.build(a, h)
    end

    {% if slug_method %}
      # Slugged form: "<slug>--<encoded_id>". The slug text comes from
      # calling `{{ slug_method.id }}` on the instance — typically a method
      # like `def name_for_encoded_id_slug; name; end`.
      def slugged_encoded_id : ::String?
        e = encoded_id
        return nil if e.nil?
        ::MartenEncodedId::SluggedId.build({{ slug_method.id }}.to_s, e)
      end
    {% end %}

    def to_param : ::String
      e = encoded_id
      raise ::ArgumentError.new("Cannot create path param for #{self.class} without an encoded id") if e.nil?
      e
    end
  end
end
