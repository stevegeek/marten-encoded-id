# Test model with explicit coder + prefix + slug_method.
# Exercises encoded_id annotation and slugged_encoded_id.
class Gizmo < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :name, :string, max_size: 255

  MartenEncodedId.use(
    coder: ::EncodedId::ReversibleId.hashid(salt: "gizmo-test-salt", min_hash_length: 6),
    prefix: "gizmo",
    slug_method: name,
  )
end
