require "spec"
require "../src/marten_encoded_id/composite_id"

describe MartenEncodedId::AnnotatedId do
  it "builds an annotated id with the default separator" do
    MartenEncodedId::AnnotatedId.build("user", "p5w9-z27j").should eq "user_p5w9-z27j"
  end

  it "parameterises the prefix (lowercase + hyphenate)" do
    MartenEncodedId::AnnotatedId.build("My Cool Item", "abc-def").should eq "my-cool-item_abc-def"
    MartenEncodedId::AnnotatedId.build("Foo!Bar", "abc-def").should eq "foo-bar_abc-def"
  end

  it "rejects empty inputs" do
    expect_raises(ArgumentError) { MartenEncodedId::AnnotatedId.build("", "abc") }
    expect_raises(ArgumentError) { MartenEncodedId::AnnotatedId.build("user", "") }
  end

  it "parses by stripping the last separator-delimited prefix" do
    MartenEncodedId::AnnotatedId.parse("user_p5w9-z27j").should eq "p5w9-z27j"
    MartenEncodedId::AnnotatedId.parse("p5w9-z27j").should eq "p5w9-z27j"
  end

  it "parses correctly when the prefix itself contained the separator" do
    # Per the build rule, multi-word prefixes are parameterised to use
    # hyphens, but if a user produced "first_part_id" by hand we still pick
    # the LAST separator.
    MartenEncodedId::AnnotatedId.parse("first_part_id").should eq "id"
  end
end

describe MartenEncodedId::SluggedId do
  it "builds a slugged id with the default `--` separator" do
    MartenEncodedId::SluggedId.build("My Product", "p5w9-z27j").should eq "my-product--p5w9-z27j"
  end

  it "round-trips a slug+annotated id" do
    annotated = MartenEncodedId::AnnotatedId.build("user", "p5w9-z27j")
    slugged = MartenEncodedId::SluggedId.build("Big Boss", annotated)
    slugged.should eq "big-boss--user_p5w9-z27j"

    after_slug = MartenEncodedId::SluggedId.parse(slugged)
    after_slug.should eq "user_p5w9-z27j"
    MartenEncodedId::AnnotatedId.parse(after_slug).should eq "p5w9-z27j"
  end

  it "leaves an unwrapped id alone" do
    MartenEncodedId::SluggedId.parse("plain-id").should eq "plain-id"
  end
end
