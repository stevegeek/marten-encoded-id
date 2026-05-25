require "./spec_helper"

# H2 compile-time PK guard verification.
#
# `MartenEncodedId.use` introspects the host model's primary-key field
# type at compile time and refuses to expand for unsupported types
# (UUID, string, etc.). Because `{% raise %}` aborts compilation, the
# negative cases must be exercised by shelling out to `crystal build`
# against a tiny dummy program rather than included in this spec
# compilation unit.
#
# Each negative case below is a self-contained Crystal program; we
# compile it (without code generation) and assert the error message
# names both the offending field type and `MartenEncodedId.use`.

require "process"
require "file_utils"

# Path bookkeeping so the dummy program can find the shard. We resolve
# from this spec file outward.
private SHARD_ROOT = File.expand_path("..", __DIR__)

private def with_dummy_compile(model_body : String, &)
  # The dummy program lives next to the spec files so its `require`
  # resolves the shard's own source (which itself pulls in `marten` via
  # the lib/ symlink set up by `shards install`).
  source = <<-CR
  require "../src/marten_encoded_id"

  class MartenEncodedIdPkGuardSpecApp < Marten::App
    label :marten_encoded_id_pk_guard_spec
  end

  #{model_body}

  Marten.configure :test do |config|
    config.secret_key = "_x_"
    config.installed_apps = [MartenEncodedIdPkGuardSpecApp]
    config.database do |db|
      db.backend = :sqlite
      db.name = ":memory:"
    end
  end
  CR

  tmp = File.tempname("marten_encoded_id_pk_guard_", ".cr", dir: "#{SHARD_ROOT}/spec")
  File.write(tmp, source)
  io = IO::Memory.new
  begin
    # Use the wrapper script that sets CRYSTAL_LIBRARY_PATH; cwd must be
    # the shard root so the dummy program's `require` resolves `lib/`.
    status = Process.run(
      "#{SHARD_ROOT}/script/cr",
      args: ["build", "--no-codegen", tmp],
      output: io, error: io,
      chdir: SHARD_ROOT,
    )
    yield status, io.to_s
  ensure
    File.delete?(tmp)
  end
end

describe "H2: compile-time PK type guard" do
  it "rejects a model with a :uuid primary key" do
    with_dummy_compile(<<-CR) do |status, output|
      class GuardUuidModel < Marten::Model
        field :id, :uuid, primary_key: true
        MartenEncodedId.use(
          coder: ::EncodedId::ReversibleId.hashid(salt: "x", min_hash_length: 6),
        )
      end
    CR
      status.success?.should be_false
      output.should match /MartenEncodedId\.use/
      output.should match /uuid/i
    end
  end

  it "rejects a model with a :string primary key" do
    with_dummy_compile(<<-CR) do |status, output|
      class GuardStringModel < Marten::Model
        field :id, :string, max_size: 32, primary_key: true
        MartenEncodedId.use(
          coder: ::EncodedId::ReversibleId.hashid(salt: "x", min_hash_length: 6),
        )
      end
    CR
      status.success?.should be_false
      output.should match /MartenEncodedId\.use/
      output.should match /string/i
    end
  end

  it "accepts a model with a :big_int primary key" do
    with_dummy_compile(<<-CR) do |status, _output|
      class GuardBigIntModel < Marten::Model
        field :id, :big_int, primary_key: true, auto: true
        MartenEncodedId.use(
          coder: ::EncodedId::ReversibleId.hashid(salt: "x", min_hash_length: 6),
        )
      end
    CR
      status.success?.should be_true
    end
  end

  it "accepts a model with an :int primary key" do
    with_dummy_compile(<<-CR) do |status, _output|
      class GuardIntModel < Marten::Model
        field :id, :int, primary_key: true, auto: true
        MartenEncodedId.use(
          coder: ::EncodedId::ReversibleId.hashid(salt: "x", min_hash_length: 6),
        )
      end
    CR
      status.success?.should be_true
    end
  end
end
