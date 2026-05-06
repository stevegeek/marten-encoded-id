# Test model with explicit coder, no prefix, no slug method.
# Exercises the basic encode/decode/find_by paths.
class Widget < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :name, :string, max_size: 255

  MartenEncodedId.use(
    coder: ::EncodedId::ReversibleId.hashid(salt: "widget-test-salt", min_hash_length: 6),
  )
end
