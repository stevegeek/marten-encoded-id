require "encoded_id_cr"
require "marten"

require "./encoded_id_marten/composite_id"

# Wires `encoded_id` semantics from the Ruby `encoded_id-rails` gem onto
# Marten models: encode/decode class methods, finder methods that hide the
# underlying integer primary key, and instance methods that return the
# (optionally annotated) encoded id for use as a URL parameter.
#
# Usage inside a Marten model body:
#
#     class Item < Marten::Model
#       field :id, :big_int, primary_key: true, auto: true
#       field :name, :string
#
#       EncodedIdMarten.use(
#         coder: EncodedId::ReversibleId.hashid(salt: "item-salt", min_hash_length: 8),
#         prefix: "item",   # optional; produces "item_3z7e-87kw" form
#       )
#     end
#
# After `use`, `Item.find_by_encoded_id("item_3z7e-87kw")` returns the model
# instance, and `item.encoded_id` returns the URL-friendly form.
module EncodedIdMarten
  VERSION = "0.1.0"

  macro use(coder, prefix = nil)
    # Coder is constructed lazily and memoized on the first access. The
    # `||=` pattern keeps thread-safety simple under Marten's worker model
    # (single-process loaded once at boot; we accept a benign double-init in
    # the (vanishingly rare) case of concurrent first access).
    @@_encoded_id_coder : ::EncodedId::ReversibleId? = nil

    def self.encoded_id_coder : ::EncodedId::ReversibleId
      @@_encoded_id_coder ||= ({{coder}})
    end

    def self.encoded_id_prefix : String?
      {{ prefix }}
    end

    # ------- Class methods -------

    def self.encode_encoded_id(id : Int) : String
      encoded_id_coder.encode(id.to_i64)
    end

    def self.encode_encoded_id(ids : Array(T)) : String forall T
      encoded_id_coder.encode(ids.map(&.to_i64))
    end

    # Decode a possibly-annotated, possibly-slugged id back to its integer
    # array. Returns [] (rather than raising) on garbage input — finder
    # methods then translate that to nil/RecordNotFound as appropriate.
    def self.decode_encoded_id(input : String) : Array(Int64)
      payload = ::EncodedIdMarten::SluggedId.parse(input)
      payload = ::EncodedIdMarten::AnnotatedId.parse(payload)
      encoded_id_coder.decode(payload)
    rescue ::EncodedId::EncodedIdFormatError
      [] of ::Int64
    end

    # Returns the model or nil. Mirrors Rails' `find_by_encoded_id` semantics.
    def self.find_by_encoded_id(input : String)
      ids = decode_encoded_id(input)
      return nil if ids.empty?
      get(pk: ids.first)
    end

    # Raises `Marten::DB::Errors::RecordNotFound` when the input doesn't
    # decode or the row isn't there.
    def self.find_by_encoded_id!(input : String)
      ids = decode_encoded_id(input)
      raise ::Marten::DB::Errors::RecordNotFound.new("not found for encoded id: #{input}") if ids.empty?
      get!(pk: ids.first)
    end

    # For multi-id encodings — returns all rows whose ids appear in the
    # decoded list. Empty array if input doesn't decode.
    def self.find_all_by_encoded_id(input : String)
      ids = decode_encoded_id(input)
      return [] of self if ids.empty?
      filter(pk__in: ids).to_a
    end

    # ------- Instance methods -------

    # The raw encoded id with no prefix/slug wrapping. nil if unsaved.
    def encoded_id_hash : ::String?
      pk_v = pk
      return nil if pk_v.nil?
      self.class.encode_encoded_id(pk_v.as(::Int64))
    end

    # The encoded id, annotated with the configured prefix if any.
    # e.g. "item_3z7e-87kw" or just "3z7e-87kw" if no prefix.
    def encoded_id : ::String?
      h = encoded_id_hash
      return nil if h.nil?
      a = self.class.encoded_id_prefix
      a.nil? ? h : ::EncodedIdMarten::AnnotatedId.build(a, h)
    end

    # Direct drop-in for use as a URL parameter — raises if unsaved.
    def to_param : ::String
      e = encoded_id
      raise ::ArgumentError.new("Cannot create path param for #{self.class} without an encoded id") if e.nil?
      e
    end
  end
end
