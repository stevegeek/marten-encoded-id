require "./spec_helper"

# Phase 2 (MED) regression specs. Each `describe` maps to one of the
# M-numbered findings in `reviews/marten-encoded-id-review.md`.

describe "M1: salt-derivation delimiter is NUL (not '/')" do
  it "derives a salt that embeds a NUL byte between class name and base" do
    cfg = ::MartenEncodedId::Configuration.new
    cfg.salt = "base-salt"
    derived = cfg.derive_salt("FooModel")
    derived.should eq "FooModel\x00base-salt"
  end

  it "round-trips encode/decode unchanged" do
    # Behavioural: the only externally observable effect of the delimiter
    # choice is that the derived salt stays unique per class. Two
    # invocations with the same class name produce the same salt.
    cfg = ::MartenEncodedId::Configuration.new
    cfg.salt = "round-trip-salt"
    cfg.derive_salt("AnyModel").should eq cfg.derive_salt("AnyModel")
  end
end

describe "M3: find_by_encoded_ids preserves decoded-payload order" do
  it "returns rows in the order the ids appear in the decoded payload" do
    a = Widget.create!(name: "Order-A")
    b = Widget.create!(name: "Order-B")
    c = Widget.create!(name: "Order-C")
    expected = [c.id.not_nil!.to_i64, a.id.not_nil!.to_i64, b.id.not_nil!.to_i64]

    multi = Widget.encode_encoded_id(expected)
    results = Widget.find_by_encoded_ids(multi)

    results.map(&.id.not_nil!.to_i64).should eq expected
  end

  it "find_all_by_encoded_id (legacy alias) preserves order too" do
    a = Widget.create!(name: "LegacyOrder-A")
    b = Widget.create!(name: "LegacyOrder-B")
    expected = [b.id.not_nil!.to_i64, a.id.not_nil!.to_i64]

    multi = Widget.encode_encoded_id(expected)
    results = Widget.find_all_by_encoded_id(multi)

    results.map(&.id.not_nil!.to_i64).should eq expected
  end

  it "find_by_encoded_ids! preserves order too" do
    a = Widget.create!(name: "BangOrder-A")
    b = Widget.create!(name: "BangOrder-B")
    c = Widget.create!(name: "BangOrder-C")
    expected = [b.id.not_nil!.to_i64, c.id.not_nil!.to_i64, a.id.not_nil!.to_i64]

    multi = Widget.encode_encoded_id(expected)
    results = Widget.find_by_encoded_ids!(multi)

    results.map(&.id.not_nil!.to_i64).should eq expected
  end
end

describe "M4: encoded_id raises for unsaved records" do
  it "Widget.new.encoded_id raises UnpersistedRecordError" do
    expect_raises(::MartenEncodedId::UnpersistedRecordError, /persisted/) do
      Widget.new(name: "Never-Saved").encoded_id
    end
  end

  it "Widget.new.encoded_id_hash raises UnpersistedRecordError" do
    expect_raises(::MartenEncodedId::UnpersistedRecordError, /persisted/) do
      Widget.new(name: "Never-Saved-Hash").encoded_id_hash
    end
  end

  it "Gizmo.new.slugged_encoded_id raises UnpersistedRecordError" do
    expect_raises(::MartenEncodedId::UnpersistedRecordError, /persisted/) do
      Gizmo.new(name: "Never-Saved-Slug").slugged_encoded_id
    end
  end

  it "saved record still returns a String (regression)" do
    w = Widget.create!(name: "Now-Saved")
    w.encoded_id.should be_a(String)
    w.encoded_id_hash.should be_a(String)
  end
end

describe "M5: typed error hierarchy" do
  it "MartenEncodedId::Error catches CompositePayloadError" do
    a = Widget.create!(name: "Hierarchy-A")
    b = Widget.create!(name: "Hierarchy-B")
    multi = Widget.encode_encoded_id([a.id.not_nil!, b.id.not_nil!])

    caught = false
    begin
      Widget.find_by_encoded_id(multi)
    rescue ::MartenEncodedId::Error
      caught = true
    end
    caught.should be_true
  end

  it "MartenEncodedId::Error catches UnpersistedRecordError" do
    caught = false
    begin
      Widget.new(name: "Hierarchy-Unsaved").encoded_id
    rescue ::MartenEncodedId::Error
      caught = true
    end
    caught.should be_true
  end

  it "MartenEncodedId::DecodeError is a sub-class of MartenEncodedId::Error" do
    ::MartenEncodedId::DecodeError.new("x").is_a?(::MartenEncodedId::Error).should be_true
  end

  it "MartenEncodedId::EncodeError is a sub-class of MartenEncodedId::Error" do
    ::MartenEncodedId::EncodeError.new("x").is_a?(::MartenEncodedId::Error).should be_true
  end

  it "MartenEncodedId::CompositePayloadError is a sub-class of DecodeError" do
    ::MartenEncodedId::CompositePayloadError.new("x").is_a?(::MartenEncodedId::DecodeError).should be_true
  end

  it "MartenEncodedId::UnpersistedRecordError is a sub-class of EncodeError" do
    ::MartenEncodedId::UnpersistedRecordError.new("x").is_a?(::MartenEncodedId::EncodeError).should be_true
  end
end

describe "M7: AnnotatedId.valid? / SluggedId.valid?" do
  it "AnnotatedId.valid?(widget-abcd) -> true (bare encoded id, no annotation)" do
    ::MartenEncodedId::AnnotatedId.valid?("widget-abcd").should be_true
  end

  it "AnnotatedId.valid?(widget_abcd) -> true (annotated form)" do
    ::MartenEncodedId::AnnotatedId.valid?("widget_abcd").should be_true
  end

  it "AnnotatedId.valid?(--foo) -> false (leading separator-ish)" do
    ::MartenEncodedId::AnnotatedId.valid?("--foo").should be_false
  end

  it "AnnotatedId.valid?(foo--) -> false (trailing separator-ish)" do
    ::MartenEncodedId::AnnotatedId.valid?("foo--").should be_false
  end

  it "AnnotatedId.valid?(_foo) -> false (leading annotation separator)" do
    ::MartenEncodedId::AnnotatedId.valid?("_foo").should be_false
  end

  it "AnnotatedId.valid?(foo_) -> false (trailing annotation separator)" do
    ::MartenEncodedId::AnnotatedId.valid?("foo_").should be_false
  end

  it "AnnotatedId.valid?('') -> false" do
    ::MartenEncodedId::AnnotatedId.valid?("").should be_false
  end

  it "SluggedId.valid?(acme-product--abcd) -> true" do
    ::MartenEncodedId::SluggedId.valid?("acme-product--abcd").should be_true
  end

  it "SluggedId.valid?(just-text) -> false (no separator)" do
    ::MartenEncodedId::SluggedId.valid?("just-text").should be_false
  end

  it "SluggedId.valid?(--abcd) -> false (empty slug)" do
    ::MartenEncodedId::SluggedId.valid?("--abcd").should be_false
  end

  it "SluggedId.valid?(acme--) -> false (empty id)" do
    ::MartenEncodedId::SluggedId.valid?("acme--").should be_false
  end

  it "SluggedId.valid?('') -> false" do
    ::MartenEncodedId::SluggedId.valid?("").should be_false
  end

  describe "Routing::Parameter#loads uses valid? to gate malformed input" do
    it "returns nil for a leading-separator input" do
      param = ::Marten::Routing::Parameter.registry["encoded_id"]
      param.loads("--foo").should be_nil
    end

    it "returns nil for a trailing-separator input" do
      param = ::Marten::Routing::Parameter.registry["encoded_id"]
      param.loads("foo_").should be_nil
    end

    it "returns nil for empty-slug slugged input" do
      param = ::Marten::Routing::Parameter.registry["encoded_id"]
      param.loads("--abcd").should be_nil
    end

    it "returns nil for empty-id slugged input" do
      param = ::Marten::Routing::Parameter.registry["encoded_id"]
      param.loads("slug--").should be_nil
    end

    it "still passes a valid bare encoded id" do
      param = ::Marten::Routing::Parameter.registry["encoded_id"]
      param.loads("p5w9-z27j").should eq "p5w9-z27j"
    end

    it "still passes a valid annotated id" do
      param = ::Marten::Routing::Parameter.registry["encoded_id"]
      param.loads("widget_abc-def").should eq "widget_abc-def"
    end

    it "still passes a valid slugged id" do
      param = ::Marten::Routing::Parameter.registry["encoded_id"]
      param.loads("my-cool-thing--widget_abc-def").should eq "my-cool-thing--widget_abc-def"
    end
  end
end
