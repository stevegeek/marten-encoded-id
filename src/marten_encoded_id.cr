require "encoded_id_cr"
require "marten"

require "./marten_encoded_id/composite_id"
require "./marten_encoded_id/configuration"
require "./marten_encoded_id/routing_parameter"

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
#
# Primary-key requirements
# ------------------------
# `MartenEncodedId.use` requires the host model's primary key to be one of
# the supported integer types (`:int`, `:big_int`, `:int8`, `:int16`,
# `:int32`, `:int64`). UUID and string primary keys are rejected at
# compile time because Hashids/Sqids are integer encoders by design.
module MartenEncodedId
  VERSION = "0.1.0"

  # M5 — typed error hierarchy. All shard-originated exceptions descend
  # from `MartenEncodedId::Error`, so handler code can write
  #
  #     rescue ex : ::MartenEncodedId::Error
  #
  # and catch every failure mode the shard surfaces (malformed input,
  # unpersisted records, composite payloads passed to a single-id route)
  # without enumerating three upstream namespaces
  # (`::EncodedId::*`, `::ArgumentError`, `::Marten::DB::Errors::*`).
  #
  # Specific sub-classes let callers narrow if they care about the
  # distinction between encode-side and decode-side problems.
  class Error < ::Exception; end

  class DecodeError < Error; end

  class EncodeError < Error; end

  # Raised by `encoded_id` (and `slugged_encoded_id`) when the record
  # hasn't been persisted yet. Mirrors Rails' `to_param`-on-unsaved
  # behaviour rather than silently returning `nil`, so a template that
  # builds a URL from an unsaved record fails loudly instead of producing
  # an empty href.
  class UnpersistedRecordError < EncodeError; end

  # Raised by `find_by_encoded_id` / `find_by_encoded_id!` when the
  # decoded payload contains more than one id — composite payloads must
  # go through the explicit `find_by_encoded_ids` entry point so an
  # attacker can't sneak a `[victim_id, ...]` token past a single-id
  # route handler (review finding H1).
  class CompositePayloadError < DecodeError; end

  # M3 — preserve the order in which ids appear in the decoded
  # payload. `filter(pk__in: ids)` returns rows in PK order, but
  # callers who encode `[3, 1, 2]` expect `[record-3, record-1,
  # record-2]` back. Build an `id → position` map once (O(n)) and
  # `sort_by!` against it. Missing ids in `records` (already filtered
  # out by the DB query) are simply absent from the result; we don't
  # surface them here — the bang finder handles that case.
  def self.reorder_by_ids(records : Array, ids : Array(::Int64)) : Array
    index_map = {} of ::Int64 => Int32
    ids.each_with_index { |id, i| index_map[id] = i unless index_map.has_key?(id) }
    records.sort_by! { |record| index_map[record.pk.as(::Int).to_i64] }
    records
  end

  # Set of FIELDS_-style primary-key type names this shard accepts. Both
  # Marten's documented `:big_int` / `:int` and a handful of sized aliases
  # are covered; anything else (notably `:uuid`, `:string`, FK PKs) trips a
  # compile-time error in `MartenEncodedId.use`.
  SUPPORTED_PK_TYPES = %w[big_int int int8 int16 int32 int64]

  # Compile-time PK type guard (H2). Macro-defined macros bind `@type` to
  # the macro's owning module rather than the calling class, so we route
  # the introspection through a separate `include`d module whose
  # `included` macro hook receives the host model as `@type` and can read
  # `FIELDS_` for the model's declared primary-key field type.
  module CompileTimePkGuard
    macro included
      {% if !@type.has_constant?("FIELDS_") %}
        {% raise "MartenEncodedId.use: #{@type} doesn't expose `FIELDS_` — is this a Marten::Model?" %}
      {% end %}

      {%
        pk_type = nil
        @type.constant("FIELDS_").each do |id, config|
          if config[:kwargs] && config[:kwargs][:primary_key]
            pk_type = config[:type]
          end
        end
      %}
      {% if pk_type.nil? %}
        {% raise "MartenEncodedId.use: no primary-key field declared on #{@type} — declare `field :id, :big_int, primary_key: true, auto: true` (or another integer type) before invoking the macro" %}
      {% end %}
      {% unless ::MartenEncodedId::SUPPORTED_PK_TYPES.includes?(pk_type) %}
        {% raise "MartenEncodedId.use: #{@type}'s primary key is of type :#{pk_type.id}, which is not supported (Hashids/Sqids encode integers only). Supported PK field types: #{::MartenEncodedId::SUPPORTED_PK_TYPES}. UUID/string PKs cannot be encoded by this shard." %}
      {% end %}
    end
  end

  # `coder`        — ReversibleId expression. Optional; falls back to the
  #                  global Configuration with a per-class derived salt.
  # `prefix`       — Annotation prefix (e.g. "item"). Optional.
  #                  When set, encoded_id returns "<prefix>_<hash>".
  # `slug_method`  — Method name (bare identifier) to call for the slug
  #                  text. When set, slugged_encoded_id is emitted and
  #                  returns "<slug>--<encoded_id>".
  #
  # The model's primary key must use an integer field type (see
  # `MartenEncodedId::SUPPORTED_PK_TYPES`); the macro emits a clear
  # compile-time error otherwise (UUID/string PKs are rejected — Hashids
  # and Sqids are integer-only encoders).
  macro use(coder = nil, prefix = nil, slug_method = nil)
    # H2: include the compile-time PK type guard. `included` runs in the
    # host model's `@type` context — that's where `FIELDS_` lives and the
    # only place we can introspect the model's declared primary-key type
    # from a module-level macro.
    include ::MartenEncodedId::CompileTimePkGuard

    @@_encoded_id_coder : ::EncodedId::ReversibleId? = nil

    # M2 — lazy memoisation has a benign first-touch race. Under multi-fiber
    # boot two callers could both observe `@@_encoded_id_coder == nil`,
    # both compute a `ReversibleId`, and both assign. We don't guard with a
    # mutex because the race is harmless: every coder built from the same
    # `coder` macro argument (or the same `config.build_coder(class_name)`
    # invocation) is value-equivalent — encoded/decoded output is
    # deterministic from (salt, alphabet, min_length, …). The losing fiber
    # simply discards an instance that would have produced identical
    # bytes. Don't add locking here unless you change `build_coder` to do
    # something with side effects (file I/O, RNG, etc.).
    def self.encoded_id_coder : ::EncodedId::ReversibleId
      @@_encoded_id_coder ||= (
        {% if coder %}
          ({{ coder }})
        {% else %}
          ::MartenEncodedId.config.build_coder({{ @type.name.stringify }})
        {% end %}
      )
    end

    # L7 — prefix is fixed at macro expansion time, so we emit a constant
    # rather than a class method. Reads more directly at the call site
    # (the only consumer is `encoded_id` below) and removes a method-call
    # indirection. The constant is nilable when no prefix was set, so the
    # consumer's `a.nil?` branch keeps the same shape.
    ENCODED_ID_PREFIX = {% if prefix %}({{ prefix }}).as(::String?){% else %}nil.as(::String?){% end %}

    # ------- Class methods -------

    def self.encode_encoded_id(id : Int) : String
      encoded_id_coder.encode(id.to_i64)
    end

    # L5 — constrained to `Array(::Int)`. The previous `Array(T) forall T`
    # signature compiled for any type that responds to `to_i64`, which
    # silently truncates floats and parses strings — not what callers want
    # from an "encode an array of primary keys" entry point. `::Int` is
    # the supertype of `Int8..Int128` (and `UInt*`), so `Array(Int32)`,
    # `Array(Int64)`, etc. all upcast cleanly at the call site without
    # type-annotation friction.
    def self.encode_encoded_id(ids : Array(::Int)) : String
      encoded_id_coder.encode(ids.map(&.to_i64))
    end

    # Decode a possibly-prefixed, possibly-slugged id back to its integer
    # array.
    #
    # Contract: this method is a *sanitiser*. It never raises for malformed
    # input — overflow, garbage, multibyte, empty, etc. all return an
    # empty array. Finder methods built on top translate empty results
    # into `nil` / `RecordNotFound` as appropriate. Rescues the
    # `::EncodedId::Error` base class so any encoded-id-cr exception
    # (`EncodedIdFormatError`, `DecodePayloadOverflowError`,
    # `InvalidInputError`, `BlocklistError`, `SaltError`, …) is folded
    # into the same "empty array" contract.
    def self.decode_encoded_id(input : String) : Array(Int64)
      payload = ::MartenEncodedId::SluggedId.parse(input)
      payload = ::MartenEncodedId::AnnotatedId.parse(payload)
      encoded_id_coder.decode(payload)
    rescue ::EncodedId::Error
      [] of ::Int64
    end

    # Look up a single record by encoded id. Returns `nil` if the input
    # decodes to an empty array (malformed/garbage input) or to a single
    # id that doesn't exist in the database.
    #
    # **Contract — single-id payloads only.** This method REJECTS
    # composite (multi-id) payloads with an `ArgumentError`. The rationale
    # is IDOR-safety (review H1): silently returning `ids.first` from a
    # multi-id payload lets an attacker pass `[victim_id, attacker_id]`
    # through a single-id route. Use `find_by_encoded_ids` if you need
    # composite-id lookup.
    def self.find_by_encoded_id(input : String)
      ids = decode_encoded_id(input)
      return nil if ids.empty?
      if ids.size != 1
        raise ::MartenEncodedId::CompositePayloadError.new(
          "find_by_encoded_id only accepts single-id payloads; got #{ids.size}. " \
          "Use find_by_encoded_ids for composite encodings."
        )
      end
      get(pk: ids.first)
    end

    # Bang variant of `find_by_encoded_id`. Raises
    # `Marten::DB::Errors::RecordNotFound` if no record matches; raises
    # `ArgumentError` for composite payloads (see `find_by_encoded_id`).
    def self.find_by_encoded_id!(input : String)
      ids = decode_encoded_id(input)
      raise ::Marten::DB::Errors::RecordNotFound.new("not found for encoded id: #{input}") if ids.empty?
      if ids.size != 1
        raise ::MartenEncodedId::CompositePayloadError.new(
          "find_by_encoded_id! only accepts single-id payloads; got #{ids.size}. " \
          "Use find_by_encoded_ids! for composite encodings."
        )
      end
      get!(pk: ids.first)
    end

    # Composite-finder companion to `find_by_encoded_id` that *does*
    # accept multi-id payloads. Decodes the input and returns all
    # matching rows **in the order the ids appear in the decoded
    # payload** — not in primary-key order. Callers encoding
    # `[3, 1, 2]` get `[Widget#3, Widget#1, Widget#2]` back; this
    # mirrors Rails callers' expectation that the composite token
    # preserves caller-supplied ordering.
    #
    # Returns `[] of self` for malformed/garbage input.
    def self.find_by_encoded_ids(input : String)
      ids = decode_encoded_id(input)
      return [] of self if ids.empty?
      records = filter(pk__in: ids).to_a
      ::MartenEncodedId.reorder_by_ids(records, ids)
    end

    # Bang variant of `find_by_encoded_ids` — raises
    # `Marten::DB::Errors::RecordNotFound` if the decoded id list is
    # empty (garbage input) OR if any of the requested ids has no
    # matching row. Returned records preserve the order of the
    # decoded payload (see `find_by_encoded_ids`).
    def self.find_by_encoded_ids!(input : String)
      ids = decode_encoded_id(input)
      raise ::Marten::DB::Errors::RecordNotFound.new("not found for encoded id: #{input}") if ids.empty?
      results = filter(pk__in: ids).to_a
      if results.size != ids.size
        raise ::Marten::DB::Errors::RecordNotFound.new(
          "expected #{ids.size} record(s) for encoded id '#{input}', found #{results.size}"
        )
      end
      ::MartenEncodedId.reorder_by_ids(results, ids)
    end

    # Legacy / Rails-style alias for `find_by_encoded_ids`. Kept for
    # backwards compatibility with the v0.1.0 method name.
    def self.find_all_by_encoded_id(input : String)
      find_by_encoded_ids(input)
    end

    # ------- Instance methods -------

    # M4 — encoded_id_hash REQUIRES a persisted record. Returning `nil`
    # for unsaved instances meant a template like `<a href={url_for(w)}>`
    # would silently render `<a href="">`; that's a footgun, not a
    # feature. Rails' `to_param` raises here too. Use `pk.try(&.nil?)` /
    # `persisted?` from the caller if you genuinely want to no-op.
    #
    # The return type stays nilable because `encoded_id` returns `nil`
    # from `pk.nil?` is no longer the path — but we keep the nilable
    # type so callers don't have to immediately `.not_nil!` (the
    # downstream `encoded_id` consumers were typed against it).
    def encoded_id_hash : ::String
      pk_v = pk
      if pk_v.nil?
        raise ::MartenEncodedId::UnpersistedRecordError.new(
          "encoded_id_hash requires a persisted record (no primary key yet); " \
          "call .save! before reading the encoded id."
        )
      end
      # H2: any Int PK (Int8..Int64) widens cleanly via .to_i64. The
      # macro's compile-time guard above ensures `pk` is an integer.
      self.class.encode_encoded_id(pk_v.as(::Int).to_i64)
    end

    # M4 — annotated form. Raises `UnpersistedRecordError` (via
    # `encoded_id_hash`) for unsaved records.
    def encoded_id : ::String
      h = encoded_id_hash
      a = ENCODED_ID_PREFIX
      a.nil? ? h : ::MartenEncodedId::AnnotatedId.build(a, h)
    end

    {% if slug_method %}
      # L8 — `slug_method:` must be a bare identifier (parsed as a `Path`
      # or `Var` by the macro engine). Refuse string literals, calls with
      # arguments, etc. at macro-expansion time so the failure mode is a
      # crystal-clear compile-time message rather than the surprising
      # "string literal interpolated verbatim" behaviour the un-guarded
      # macro otherwise produces.
      {% unless slug_method.is_a?(Path) || slug_method.is_a?(Var) || slug_method.is_a?(Call) && slug_method.args.empty? && slug_method.named_args.nil? && slug_method.receiver.is_a?(Nop) %}
        {% raise "MartenEncodedId.use(slug_method:): expected a bare method-name identifier (e.g. `slug_method: name`); got `#{slug_method}` of type `#{slug_method.class_name}`." %}
      {% end %}

      # Slugged form: "<slug>--<encoded_id>". The slug text comes from
      # calling `{{ slug_method.id }}` on the instance — typically a method
      # like `def name_for_encoded_id_slug; name; end`.
      #
      # M4 — raises `UnpersistedRecordError` (via `encoded_id`) for
      # unsaved records.
      def slugged_encoded_id : ::String
        e = encoded_id
        ::MartenEncodedId::SluggedId.build({{ slug_method.id }}.to_s, e)
      end
    {% end %}
  end
end
