require "./spec_helper"

describe "EncodedIdMarten end-to-end Marten model integration" do
  describe "Widget (explicit coder, no prefix, no slug_method)" do
    it "encodes the primary key on instances" do
      w = Widget.create!(name: "Cog")
      w.encoded_id_hash.should_not be_nil
      w.encoded_id.should eq w.encoded_id_hash # no prefix
    end

    it "round-trips through encode/decode at the class level" do
      w = Widget.create!(name: "Lever")
      encoded = Widget.encode_encoded_id(w.id.not_nil!)
      Widget.decode_encoded_id(encoded).should eq [w.id.not_nil!]
    end

    it "looks up via find_by_encoded_id" do
      w = Widget.create!(name: "Pulley")
      found = Widget.find_by_encoded_id(w.encoded_id.not_nil!)
      found.should_not be_nil
      found.try(&.id).should eq w.id
    end

    it "find_by_encoded_id returns nil for unknown ids" do
      Widget.find_by_encoded_id("garbage").should be_nil
    end

    it "find_by_encoded_id! raises on garbage input" do
      expect_raises(Marten::DB::Errors::RecordNotFound) do
        Widget.find_by_encoded_id!("garbage")
      end
    end

    it "two models with different salts produce different ids for the same pk" do
      # Widget and Gizmo share id=1 but their salts differ, so the encoded
      # forms must differ.
      w = Widget.create!(name: "Salt-Test-W")
      g = Gizmo.create!(name: "Salt-Test-G")
      Widget.encode_encoded_id(1_i64).should_not eq Gizmo.encode_encoded_id(1_i64)
      w.encoded_id.should_not be_nil
      g.encoded_id.should_not be_nil
    end
  end

  describe "Gizmo (prefix + slug_method)" do
    it "prefixes encoded ids with the configured annotation" do
      g = Gizmo.create!(name: "Foo Bar")
      g.encoded_id.not_nil!.should start_with "gizmo_"
    end

    it "produces a slugged encoded id from the configured method" do
      g = Gizmo.create!(name: "My Cool Gizmo!")
      slugged = g.slugged_encoded_id.not_nil!
      slugged.should start_with "my-cool-gizmo--gizmo_"
    end

    it "decodes the slugged form back to the same record" do
      g = Gizmo.create!(name: "Roundtrip")
      slugged = g.slugged_encoded_id.not_nil!
      found = Gizmo.find_by_encoded_id(slugged)
      found.try(&.id).should eq g.id
    end

    it "decodes the prefixed form back to the same record" do
      g = Gizmo.create!(name: "Direct")
      Gizmo.find_by_encoded_id(g.encoded_id.not_nil!).try(&.id).should eq g.id
    end

    it "returns nil for an id encoded under a different model's salt" do
      w = Widget.create!(name: "X-Salt")
      Gizmo.find_by_encoded_id(w.encoded_id.not_nil!).should be_nil
    end
  end

  describe "Sprocket (no explicit coder — uses EncodedIdMarten.config)" do
    it "round-trips encode/decode using the global config + class-derived salt" do
      s = Sprocket.create!(name: "Globally Configured")
      encoded = s.encoded_id.not_nil!
      encoded.should start_with "sprocket_"
      Sprocket.find_by_encoded_id(encoded).try(&.id).should eq s.id
    end

    it "produces ids that differ from a model with the same name under a different config-derived salt" do
      # Two records with the same numeric id from different models — the
      # class-name component of the derived salt must keep them apart.
      sp = Sprocket.create!(name: "A")
      Widget.encode_encoded_id(sp.id.not_nil!).should_not eq Sprocket.encode_encoded_id(sp.id.not_nil!)
    end
  end

  describe "to_param" do
    it "returns the encoded id for a saved record" do
      g = Gizmo.create!(name: "Param Test")
      g.to_param.should eq g.encoded_id
    end

    it "raises on an unsaved (nil-pk) instance" do
      g = Gizmo.new(name: "Unsaved")
      expect_raises(ArgumentError, /without an encoded id/) do
        g.to_param
      end
    end
  end

  describe "find_all_by_encoded_id (multi-id encoding)" do
    it "returns all rows whose ids appear in the decoded list" do
      a = Widget.create!(name: "A")
      b = Widget.create!(name: "B")
      c = Widget.create!(name: "C")

      multi = Widget.encode_encoded_id([a.id.not_nil!, b.id.not_nil!, c.id.not_nil!])
      results = Widget.find_all_by_encoded_id(multi)
      results.size.should eq 3
      results.map(&.id.not_nil!.to_i64).sort.should eq [a.id, b.id, c.id].map(&.not_nil!.to_i64).sort
    end
  end
end
