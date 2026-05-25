# Test model with an Int32 (:int) primary key — exercises the H2 fix
# that widens any Int PK via `.to_i64` rather than hard-casting to
# `Int64` (which used to crash here).
class Cog < Marten::Model
  field :id, :int, primary_key: true, auto: true
  field :name, :string, max_size: 255

  MartenEncodedId.use(
    coder: ::EncodedId::ReversibleId.hashid(salt: "cog-test-salt", min_hash_length: 6),
  )
end
