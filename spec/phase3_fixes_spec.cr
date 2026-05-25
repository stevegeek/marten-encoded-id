require "./spec_helper"

# Phase 3 (LOW) regression specs. Each `describe` maps to one of the
# L-numbered findings in `reviews/marten-encoded-id-review.md`.

describe "L5: encode_encoded_id(Array) is constrained to Array(Int)" do
  it "accepts Array(Int64)" do
    encoded = Widget.encode_encoded_id([1_i64, 2_i64, 3_i64])
    Widget.decode_encoded_id(encoded).should eq [1_i64, 2_i64, 3_i64]
  end

  it "accepts Array(Int32) by upcasting to Array(Int)" do
    ids = [1, 2, 3] of Int32
    # Crystal type-inferences `ids of Array(Int32)`; the method signature
    # `Array(::Int)` accepts it via Int32 <: Int.
    encoded = Widget.encode_encoded_id(ids.map(&.as(::Int)))
    Widget.decode_encoded_id(encoded).should eq [1_i64, 2_i64, 3_i64]
  end
end

describe "L7: ENCODED_ID_PREFIX is a constant on the model class" do
  it "Widget (no prefix) has ENCODED_ID_PREFIX == nil" do
    Widget::ENCODED_ID_PREFIX.should be_nil
  end

  it "Gizmo (prefix: \"gizmo\") has ENCODED_ID_PREFIX == \"gizmo\"" do
    Gizmo::ENCODED_ID_PREFIX.should eq "gizmo"
  end

  it "Sprocket (prefix: \"sprocket\") has ENCODED_ID_PREFIX == \"sprocket\"" do
    Sprocket::ENCODED_ID_PREFIX.should eq "sprocket"
  end
end

describe "L10: Configuration setters reject obviously-invalid values" do
  it "salt= rejects an empty string" do
    cfg = ::MartenEncodedId::Configuration.new
    expect_raises(::EncodedId::InvalidConfigurationError, /non-empty/) do
      cfg.salt = ""
    end
  end

  it "salt= still accepts nil (the 'unset' state)" do
    cfg = ::MartenEncodedId::Configuration.new
    cfg.salt = nil
    cfg.salt.should be_nil
  end

  it "salt= accepts a normal non-empty string" do
    cfg = ::MartenEncodedId::Configuration.new
    cfg.salt = "abc"
    cfg.salt.should eq "abc"
  end

  it "min_length= rejects a negative value" do
    cfg = ::MartenEncodedId::Configuration.new
    expect_raises(::EncodedId::InvalidConfigurationError, />= 0/) do
      cfg.min_length = -1
    end
  end

  it "min_length= accepts 0" do
    cfg = ::MartenEncodedId::Configuration.new
    cfg.min_length = 0
    cfg.min_length.should eq 0
  end
end

describe "L12: Configuration default min_length is 8" do
  it "min_length defaults to 8 on a fresh Configuration" do
    ::MartenEncodedId::Configuration.new.min_length.should eq 8
  end
end

describe "L13: sequential PK encoded forms are not adjacent" do
  it "two consecutive primary keys encode to visibly-different tokens" do
    a = Widget.create!(name: "Seq-A")
    b = Widget.create!(name: "Seq-B")

    # Sanity: the two PKs really are consecutive — that's the test setup,
    # not the property under test.
    (b.id.not_nil!.to_i64 - a.id.not_nil!.to_i64).should eq 1

    ea = a.encoded_id.not_nil!
    eb = b.encoded_id.not_nil!

    # Negative: they're not the same token.
    ea.should_not eq eb

    # The encoder's whole job is to obscure sequentiality — consecutive
    # PKs should NOT produce encoded strings that differ by one
    # character at one position. Concretely: require that the two
    # tokens differ in at least 2 character positions (or are of
    # different lengths). This is a coarse "the encoder is doing its
    # job" check rather than a cryptographic claim.
    if ea.size == eb.size
      diffs = 0
      ea.each_char_with_index do |ch, i|
        diffs += 1 if ch != eb[i]
      end
      diffs.should be > 1
    else
      # Different lengths is already non-adjacent.
      true.should be_true
    end
  end
end
