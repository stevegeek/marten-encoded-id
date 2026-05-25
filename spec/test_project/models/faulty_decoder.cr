# Test fixture for MER3: locks the breadth of `decode_encoded_id`'s
# `rescue ::EncodedId::Error` clause. The mock coder always raises
# `::EncodedId::SaltError` — a sibling of `EncodedIdFormatError` in the
# `::EncodedId::Error` hierarchy. If a future refactor narrows the rescue
# to `EncodedIdFormatError`, `FaultyDecoder.decode_encoded_id` will leak
# the `SaltError` and the regression spec under H3 (Phase 1) will fail.
class NonFormatErrorCoder < ::EncodedId::ReversibleId
  # Build via the public `.hashid` factory, then copy the internals into a
  # `NonFormatErrorCoder` instance so the subclass shares the parent's
  # construction logic without re-implementing it.
  def self.build : NonFormatErrorCoder
    base = ::EncodedId::ReversibleId.hashid(salt: "non-format-error-coder-salt")
    new(
      base.@encoder,
      base.@alphabet,
      base.@split_at,
      base.@split_with,
      base.@max_inputs_per_id,
      base.@max_length,
      4,
    )
  end

  def decode(str : String, downcase : Bool = false) : Array(Int64)
    raise ::EncodedId::SaltError.new("mock non-format error from NonFormatErrorCoder#decode")
  end
end

class FaultyDecoder < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :name, :string, max_size: 255

  MartenEncodedId.use(
    coder: NonFormatErrorCoder.build,
  )
end
