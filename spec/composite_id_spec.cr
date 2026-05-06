require "spec"
require "../src/encoded_id_marten/composite_id"

describe EncodedIdMarten::AnnotatedId do
  it "builds an annotated id with the default separator" do
    EncodedIdMarten::AnnotatedId.build("user", "p5w9-z27j").should eq "user_p5w9-z27j"
  end

  it "parameterises the prefix (lowercase + hyphenate)" do
    EncodedIdMarten::AnnotatedId.build("My Cool Item", "abc-def").should eq "my-cool-item_abc-def"
    EncodedIdMarten::AnnotatedId.build("Foo!Bar", "abc-def").should eq "foo-bar_abc-def"
  end

  it "rejects empty inputs" do
    expect_raises(ArgumentError) { EncodedIdMarten::AnnotatedId.build("", "abc") }
    expect_raises(ArgumentError) { EncodedIdMarten::AnnotatedId.build("user", "") }
  end

  it "parses by stripping the last separator-delimited prefix" do
    EncodedIdMarten::AnnotatedId.parse("user_p5w9-z27j").should eq "p5w9-z27j"
    EncodedIdMarten::AnnotatedId.parse("p5w9-z27j").should eq "p5w9-z27j"
  end

  it "parses correctly when the prefix itself contained the separator" do
    # Per the build rule, multi-word prefixes are parameterised to use
    # hyphens, but if a user produced "first_part_id" by hand we still pick
    # the LAST separator.
    EncodedIdMarten::AnnotatedId.parse("first_part_id").should eq "id"
  end
end

describe EncodedIdMarten::SluggedId do
  it "builds a slugged id with the default `--` separator" do
    EncodedIdMarten::SluggedId.build("My Product", "p5w9-z27j").should eq "my-product--p5w9-z27j"
  end

  it "round-trips a slug+annotated id" do
    annotated = EncodedIdMarten::AnnotatedId.build("user", "p5w9-z27j")
    slugged = EncodedIdMarten::SluggedId.build("Big Boss", annotated)
    slugged.should eq "big-boss--user_p5w9-z27j"

    after_slug = EncodedIdMarten::SluggedId.parse(slugged)
    after_slug.should eq "user_p5w9-z27j"
    EncodedIdMarten::AnnotatedId.parse(after_slug).should eq "p5w9-z27j"
  end

  it "leaves an unwrapped id alone" do
    EncodedIdMarten::SluggedId.parse("plain-id").should eq "plain-id"
  end
end
