# marten_encoded_id

`marten_encoded_id` is a thin macro layer over
[`encoded_id_cr`](https://github.com/stevegeek/encoded-id-cr) that adds
Rails-style **encoded id** helpers to [Marten](https://martenframework.com/)
models. It hides integer primary keys behind reversible, salt-derived,
URL-safe tokens (Hashids or Sqids), with optional `prefix_` annotations
and `slug--id` slugs.

```text
Widget #42  →  "p5w9-z27j"               (plain)
Widget #42  →  "widget_p5w9-z27j"        (annotated)
Widget #42  →  "my-cool-widget--widget_p5w9-z27j"  (slugged)
```

## Why

Sequential integer ids leak business signal (record counts, growth
rate) and enable trivial enumeration attacks. Encoded ids:

- are short, URL-safe, and human-typable;
- can be **per-model salted** so the same numeric id encodes
  differently across models;
- carry no authentication weight (they are obfuscation, **not** a
  signed bearer token — use
  [`marten-signed-id`](https://github.com/stevegeek/marten-signed-id)
  if you need that).

## Installation

```yaml
dependencies:
  marten_encoded_id:
    github: stevegeek/marten-encoded-id
```

Then `shards install` and `require "marten_encoded_id"` from somewhere
in your project (`src/project.cr` is the conventional spot).

## Usage

### Per-model configuration

```crystal
class Widget < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :name, :string, max_size: 255

  MartenEncodedId.use(
    coder: EncodedId::ReversibleId.hashid(salt: "widget-salt", min_hash_length: 8),
    prefix: "widget",
  )
end

w = Widget.create!(name: "Wrench")
w.encoded_id              # => "widget_p5w9-z27j"
Widget.find_by_encoded_id("widget_p5w9-z27j")  # => <Widget #42>
```

### Global configuration

```crystal
# config/initializers/encoded_id.cr
MartenEncodedId.configure do |c|
  c.salt       = ENV["ENCODED_ID_SALT"]   # required
  c.encoder    = :hashids                 # or :sqids
  c.min_length = 8
end

class Product < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :name, :string

  MartenEncodedId.use(prefix: "product", slug_method: name)
end
```

The per-class salt is derived from `c.salt` plus the model's full class
name, so two models with the same numeric id encode differently.

### Primary-key requirements

`MartenEncodedId.use` validates the host model's primary-key field type
at **compile time** and rejects unsupported types:

| Field type                                | Status                |
|-------------------------------------------|-----------------------|
| `:big_int`, `:int`, `:int8`/16/32/64      | supported             |
| `:uuid`, `:string`, FK PKs, anything else | rejected (compile-time error) |

The check fires whenever you write `MartenEncodedId.use`, so a typo'd
model surfaces immediately at build time rather than at the first
request.

## Routing integration

The shard registers a Marten route-parameter type called `:encoded_id`
that matches encoded-id URL segments. Use it in `config/routes.cr`:

```crystal
Marten.routes.draw do
  path "/widgets/<widget_id:encoded_id>", WidgetHandler, name: "widget_detail"
end
```

In the handler the captured value is the **raw encoded string** (the
parameter type does no per-model decoding — it can't know which model's
salt to use). Decode by calling `find_by_encoded_id`:

```crystal
class WidgetHandler < Marten::Handler
  def get
    encoded = params["widget_id"]?.try(&.as(::String))
    raise Marten::HTTP::Errors::NotFound.new("missing widget id") unless encoded
    widget = Widget.find_by_encoded_id!(encoded)
    # ...
  end
end
```

### URL parameter `nil` returns

The `:encoded_id` parameter's `loads` method is **nilable** — it returns
`nil` (not the string) when the URL segment matches the regex
character class but fails structural validation (`AnnotatedId.valid?` /
`SluggedId.valid?` reject e.g. `--foo`, `foo_`, `--abcd`, `slug--`).
That nil propagates into `params["widget_id"]` as a missing entry
rather than a `String`, so the handler **must nil-guard before the
cast**. The pattern above (`params["widget_id"]?.try(&.as(::String))`
followed by an explicit `NotFound` raise) keeps the failure inside
Marten's documented `Marten::HTTP::Errors::*` boundary instead of
leaking a `TypeCastError` past `rescue MartenEncodedId::Error`.

Reverse routing works the same way — pass the encoded string:

```crystal
reverse("widget_detail", widget_id: widget.encoded_id.not_nil!)
# => "/widgets/widget_p5w9-z27j"
```

### Why `loads` doesn't return a model instance

Marten's `Routing::Parameter::Types` is closed (`Int8..Int64 | String | UUID | Nil`)
— it doesn't admit user-defined types. And even if it did, a generic
parameter type can't know *which* model to decode against; per-model
salts mean the same string decodes to different ints depending on the
target.

The `<x:encoded_id>` parameter type therefore exists to:

1. constrain the URL segment to the encoded-id alphabet (defence in
   depth — no path-traversal characters slip through);
2. give your route declarations a self-documenting name (vs. `<x:slug>`).

## API reference

### Class methods (added by `MartenEncodedId.use`)

| Method                                | Returns                          | Notes                                                                                                  |
|---------------------------------------|----------------------------------|--------------------------------------------------------------------------------------------------------|
| `Model.encode_encoded_id(id)`         | `String`                         | Encode a single Int. Widens any `Int` to `Int64`.                                                      |
| `Model.encode_encoded_id(ids)`        | `String`                         | Encode an array of ints into a composite token.                                                        |
| `Model.decode_encoded_id(input)`      | `Array(Int64)`                   | Decode. Never raises — garbage / overflow / malformed input all return `[]` (rescues `::EncodedId::Error`). |
| `Model.find_by_encoded_id(input)`     | `Model?`                         | Single-id lookup. **Raises `MartenEncodedId::CompositePayloadError` on multi-id payloads** (IDOR guard). |
| `Model.find_by_encoded_id!(input)`    | `Model`                          | Bang variant. Raises `RecordNotFound` on miss; `CompositePayloadError` on multi-id payloads.           |
| `Model.find_by_encoded_ids(input)`    | `Array(Model)`                   | Composite lookup. Accepts multi-id payloads. **Returns rows in the order the ids appear in the decoded payload.** Returns `[]` on garbage input. |
| `Model.find_by_encoded_ids!(input)`   | `Array(Model)`                   | Bang variant. Raises `RecordNotFound` on garbage *or* if any id has no matching row. Returned rows preserve decoded-payload order. |
| `Model.find_all_by_encoded_id(input)` | `Array(Model)`                   | Legacy alias for `find_by_encoded_ids`.                                                                |

### Instance methods (added by `MartenEncodedId.use`)

| Method                       | Returns   | Notes                                                                  |
|------------------------------|-----------|------------------------------------------------------------------------|
| `instance.encoded_id_hash`   | `String`  | The bare encoded hash (no prefix). **Raises `MartenEncodedId::UnpersistedRecordError`** for unsaved records (mirrors Rails' `to_param`). |
| `instance.encoded_id`        | `String`  | Annotated form if `prefix:` was set; otherwise same as `encoded_id_hash`. Raises `UnpersistedRecordError` for unsaved records. |
| `instance.slugged_encoded_id`| `String`  | Defined only when `slug_method:` is set. Returns `"<slug>--<encoded_id>"`. Raises `UnpersistedRecordError` for unsaved records. |

## Security notes

- **Encoded ids are obfuscation, not authentication.** Anyone who holds
  one can decode it to the underlying integer if they know the salt.
  Use `marten-signed-id` for tamper-proof tokens. Comparison of encoded
  ids uses plain `==` (no constant-time check) — they aren't bearer
  tokens, don't treat them as such.
- **Per-model salts are not a secret.** They're derived from
  `c.salt + class_name` so the same `c.salt` is reused across models;
  rotate `c.salt` if you suspect compromise (all outstanding ids
  invalidate).
- **Multi-id payloads are dangerous in single-id routes.**
  `find_by_encoded_id` raises `MartenEncodedId::CompositePayloadError`
  rather than silently returning `ids.first`; this prevents an attacker
  who controls a composite token from passing it through a route
  expecting a single-id token.

## Error hierarchy

All exceptions the shard raises descend from `MartenEncodedId::Error`,
so handler code can catch every failure mode in one block:

```crystal
class WidgetHandler < Marten::Handler
  def get
    encoded = params["widget_id"]?.try(&.as(::String))
    raise Marten::HTTP::Errors::NotFound.new("missing widget id") unless encoded
    widget = Widget.find_by_encoded_id!(encoded)
    # ...
  rescue ::MartenEncodedId::Error => ex
    # malformed token, composite payload in a single-id route,
    # unpersisted record in a URL helper, ...
    head 404
  end
end
```

```
MartenEncodedId::Error                ← root; catches everything below
├── MartenEncodedId::EncodeError
│   └── MartenEncodedId::UnpersistedRecordError   (encoded_id on unsaved record)
└── MartenEncodedId::DecodeError
    └── MartenEncodedId::CompositePayloadError    (multi-id token in find_by_encoded_id)
```

`Marten::DB::Errors::RecordNotFound` (raised by `find_by_encoded_id!`
on miss) and `::EncodedId::InvalidConfigurationError` (raised by
`Configuration#build_coder`) remain in their original namespaces —
they predate this shard and are documented separately.

## Configuration `min_length` (Hashids vs Sqids)

The upstream encoders disagree on the name for "minimum encoded
length": Hashids calls it `min_hash_length`, Sqids calls it
`min_length`. `MartenEncodedId::Configuration` exposes a single
`min_length` and forwards it under the right name when it builds the
underlying coder. Per-model explicit coders constructed with
`EncodedId::ReversibleId.hashid(...)` / `.sqids(...)` keep the
upstream parameter names.

## Configuration reference

```crystal
MartenEncodedId.configure do |c|
  c.salt                    = "..."           # required for non-explicit coders
  c.encoder                 = :hashids        # or :sqids
  c.alphabet                = ::EncodedId::Alphabet.modified_crockford
  c.min_length              = 8               # min encoded length
  c.max_length              = 128             # rejects decode inputs longer than this
  c.max_inputs_per_id       = 32
  c.character_group_size    = 4               # "abcd-efgh-ijkl" grouping
  c.group_separator         = "-"
  c.annotated_id_separator  = "_"             # the "_" in "widget_<id>"
  c.slugged_id_separator    = "--"            # the "--" in "<slug>--<id>"
  c.blocklist               = ::EncodedId::Blocklist.empty
end
```

The three separators (`group_separator`, `annotated_id_separator`,
`slugged_id_separator`) must all differ; otherwise the
parse passes can't tell them apart. Misconfigurations raise
`::EncodedId::InvalidConfigurationError` when the coder is first built.

## Development

```sh
script/cr spec               # run specs
bin/ameba src/               # lint
```

## License

MIT.
