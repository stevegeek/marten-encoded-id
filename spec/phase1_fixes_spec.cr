require "./spec_helper"

# Phase 1 (CRIT + HIGH) regression specs. Each `describe` maps to one of
# the H-numbered findings from `reviews/marten-encoded-id-review.md`.

describe "H1: find_by_encoded_id rejects multi-id payloads (IDOR guard)" do
  it "raises CompositePayloadError when a multi-id payload is passed to find_by_encoded_id" do
    a = Widget.create!(name: "Multi-A")
    b = Widget.create!(name: "Multi-B")
    multi = Widget.encode_encoded_id([a.id.not_nil!, b.id.not_nil!])

    expect_raises(MartenEncodedId::CompositePayloadError, /single-id payloads/) do
      Widget.find_by_encoded_id(multi)
    end
  end

  it "raises CompositePayloadError when a multi-id payload is passed to find_by_encoded_id!" do
    a = Widget.create!(name: "Bang-A")
    b = Widget.create!(name: "Bang-B")
    multi = Widget.encode_encoded_id([a.id.not_nil!, b.id.not_nil!])

    expect_raises(MartenEncodedId::CompositePayloadError, /single-id payloads/) do
      Widget.find_by_encoded_id!(multi)
    end
  end

  it "still works for a legitimate single-id payload" do
    w = Widget.create!(name: "Single")
    Widget.find_by_encoded_id(w.encoded_id.not_nil!).try(&.id).should eq w.id
  end

  it "find_by_encoded_ids succeeds for multi-id payloads" do
    a = Widget.create!(name: "Composite-A")
    b = Widget.create!(name: "Composite-B")
    multi = Widget.encode_encoded_id([a.id.not_nil!, b.id.not_nil!])

    results = Widget.find_by_encoded_ids(multi)
    results.size.should eq 2
    results.map(&.id.not_nil!.to_i64).sort!.should eq [a.id.not_nil!.to_i64, b.id.not_nil!.to_i64].sort!
  end

  it "find_by_encoded_ids returns [] for malformed/garbage input" do
    Widget.find_by_encoded_ids("garbage").should be_empty
  end

  it "find_by_encoded_ids! raises RecordNotFound for garbage input" do
    expect_raises(Marten::DB::Errors::RecordNotFound) do
      Widget.find_by_encoded_ids!("garbage")
    end
  end

  it "find_by_encoded_ids! raises when some ids in the payload don't exist" do
    a = Widget.create!(name: "Exists-A")
    # Encode an existing id with a non-existent very-large id.
    multi = Widget.encode_encoded_id([a.id.not_nil!, 999_999_999_i64])

    expect_raises(Marten::DB::Errors::RecordNotFound) do
      Widget.find_by_encoded_ids!(multi)
    end
  end

  it "find_all_by_encoded_id (legacy alias) still works" do
    a = Widget.create!(name: "Legacy-A")
    b = Widget.create!(name: "Legacy-B")
    multi = Widget.encode_encoded_id([a.id.not_nil!, b.id.not_nil!])

    results = Widget.find_all_by_encoded_id(multi)
    results.size.should eq 2
  end
end

describe "H2: Int32 primary key support" do
  it "Cog (Int32 :int pk) encodes its primary key" do
    c = Cog.create!(name: "Int32-Cog")
    c.encoded_id_hash.should_not be_nil
    c.encoded_id.should_not be_nil
  end

  it "Cog round-trips through encode/decode" do
    c = Cog.create!(name: "Int32-Roundtrip")
    encoded = c.encoded_id.not_nil!
    found = Cog.find_by_encoded_id(encoded)
    found.try(&.id).should eq c.id
  end

  it "Cog supports composite (multi-id) encoding via find_by_encoded_ids" do
    a = Cog.create!(name: "Int32-Comp-A")
    b = Cog.create!(name: "Int32-Comp-B")
    multi = Cog.encode_encoded_id([a.id.not_nil!, b.id.not_nil!])
    Cog.find_by_encoded_ids(multi).size.should eq 2
  end
end

describe "H3: decode_encoded_id rescues the full EncodedId::Error hierarchy" do
  it "returns [] for empty input" do
    Widget.decode_encoded_id("").should eq([] of Int64)
  end

  it "returns [] for plain garbage input" do
    Widget.decode_encoded_id("not-a-real-id").should eq([] of Int64)
  end

  it "returns [] for multibyte input" do
    Widget.decode_encoded_id("日本語").should eq([] of Int64)
  end

  it "returns [] for overflow-attempt input (a long alphabet-only string)" do
    # Hashids' decode internals do base-N arithmetic; an attacker-controlled
    # long input would otherwise overflow Int64. The upstream encoder
    # raises DecodePayloadOverflowError (subclass of InvalidInputError); the
    # encoded-id-cr ReversibleId#decode wraps that into EncodedIdFormatError;
    # our rescue covers the full ::EncodedId::Error tree.
    Widget.decode_encoded_id("a" * 200).should eq([] of Int64)
  end

  it "returns [] when input contains control bytes / arbitrary chars" do
    Widget.decode_encoded_id("\x00\x01\x02").should eq([] of Int64)
    Widget.decode_encoded_id("!@#$%^&*()").should eq([] of Int64)
  end

  it "find_by_encoded_id surfaces garbage input as nil, not a 500" do
    # The whole point of H3 — these all used to potentially leak as 500s.
    Widget.find_by_encoded_id("").should be_nil
    Widget.find_by_encoded_id("not-a-real-id").should be_nil
    Widget.find_by_encoded_id("日本語").should be_nil
    Widget.find_by_encoded_id("a" * 200).should be_nil
  end

  it "rescues non-EncodedIdFormatError EncodedId::Error subclasses (MER3 mutation-test lock)" do
    # `FaultyDecoder`'s mock coder always raises `::EncodedId::SaltError` —
    # a sibling of `EncodedIdFormatError` in the `::EncodedId::Error` tree.
    # The H3 fix widened the rescue from `EncodedIdFormatError` to
    # `::EncodedId::Error`; if a future refactor narrows it back, this
    # spec fails because `SaltError` will leak out of `decode_encoded_id`.
    FaultyDecoder.decode_encoded_id("anything").should eq([] of Int64)
  end
end

describe "H4: Configuration rejects separator collisions" do
  # Save + restore the singleton so we don't poison other specs.
  around_each do |spec|
    saved = ::MartenEncodedId.config
    begin
      spec.run
    ensure
      ::MartenEncodedId.config = saved
    end
  end

  it "raises InvalidConfigurationError when group_separator == annotated_id_separator" do
    cfg = ::MartenEncodedId::Configuration.new
    cfg.salt = "test"
    cfg.group_separator = "_"
    cfg.annotated_id_separator = "_"
    expect_raises(::EncodedId::InvalidConfigurationError, /annotated_id_separator/) do
      cfg.build_coder("Whatever")
    end
  end

  it "raises InvalidConfigurationError when group_separator == slugged_id_separator" do
    cfg = ::MartenEncodedId::Configuration.new
    cfg.salt = "test"
    cfg.group_separator = "--"
    cfg.slugged_id_separator = "--"
    expect_raises(::EncodedId::InvalidConfigurationError, /slugged_id_separator/) do
      cfg.build_coder("Whatever")
    end
  end

  it "raises InvalidConfigurationError when annotated_id_separator == slugged_id_separator" do
    cfg = ::MartenEncodedId::Configuration.new
    cfg.salt = "test"
    cfg.annotated_id_separator = "::"
    cfg.slugged_id_separator = "::"
    expect_raises(::EncodedId::InvalidConfigurationError, /annotated_id_separator/) do
      cfg.build_coder("Whatever")
    end
  end

  it "raises InvalidConfigurationError when any separator is empty" do
    cfg = ::MartenEncodedId::Configuration.new
    cfg.salt = "test"
    cfg.group_separator = ""
    expect_raises(::EncodedId::InvalidConfigurationError, /non-empty/) do
      cfg.build_coder("Whatever")
    end
  end

  it "accepts the default configuration" do
    cfg = ::MartenEncodedId::Configuration.new
    cfg.salt = "test"
    # default: group="-", annotated="_", slugged="--" — all distinct
    cfg.build_coder("Whatever").should be_a(::EncodedId::ReversibleId)
  end
end

describe "H5: Marten Routing::Parameter integration" do
  it "registers under the name :encoded_id" do
    ::Marten::Routing::Parameter.registry.has_key?("encoded_id").should be_true
  end

  it "loads returns the raw encoded string" do
    param = ::Marten::Routing::Parameter.registry["encoded_id"]
    param.loads("widget_abc-def").should eq "widget_abc-def"
  end

  it "dumps a String value back to the same String" do
    param = ::Marten::Routing::Parameter.registry["encoded_id"]
    param.dumps("widget_abc-def").should eq "widget_abc-def"
  end

  it "dumps non-String value returns nil (signals NoReverseMatch)" do
    param = ::Marten::Routing::Parameter.registry["encoded_id"]
    param.dumps(42).should be_nil
  end

  it "regex matches a typical encoded-id URL segment" do
    param = ::Marten::Routing::Parameter.registry["encoded_id"]
    encoded = Widget.create!(name: "Route-Test").encoded_id.not_nil!
    encoded.matches?(param.regex).should be_true
  end

  it "regex matches an annotated id" do
    param = ::Marten::Routing::Parameter.registry["encoded_id"]
    g = Gizmo.create!(name: "Annotated-Route")
    encoded = g.encoded_id.not_nil!
    encoded.matches?(param.regex).should be_true
  end

  it "regex matches a slugged id" do
    param = ::Marten::Routing::Parameter.registry["encoded_id"]
    g = Gizmo.create!(name: "Slugged-Route")
    slugged = g.slugged_encoded_id.not_nil!
    slugged.matches?(param.regex).should be_true
  end

  it "round-trip via the registered parameter type" do
    # End-to-end: a route segment captured into params is just the raw
    # encoded string; the handler decodes it via find_by_encoded_id.
    param = ::Marten::Routing::Parameter.registry["encoded_id"]
    w = Widget.create!(name: "Round-Trip")
    raw = w.encoded_id.not_nil!

    loaded = param.loads(raw)
    loaded.should eq raw
    Widget.find_by_encoded_id(loaded.as(String)).try(&.id).should eq w.id

    dumped = param.dumps(loaded)
    dumped.should eq raw
  end

  it "can be used in a Marten route declaration" do
    # Building a route that uses the parameter type proves registration
    # ran *and* the regex compiles inside Marten's path machinery.
    map = ::Marten::Routing::Map.draw do
      path "/widgets/<widget_id:encoded_id>", ::Marten::Handler, name: "h5_widget_detail"
    end
    map.should be_a(::Marten::Routing::Map)

    # Reverse-resolve with an encoded id String -> matches the URL.
    w = Widget.create!(name: "Reverse-Test")
    encoded = w.encoded_id.not_nil!
    map.reverse("h5_widget_detail", widget_id: encoded).should eq "/widgets/#{encoded}"
  end
end
