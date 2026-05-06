# Test model that uses the global MartenEncodedId config (no explicit coder).
# Salt is derived from class name + the global config.salt.
class Sprocket < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :name, :string, max_size: 255

  MartenEncodedId.use(prefix: "sprocket")
end
