# frozen_string_literal: true

RSpec.describe TTY::File, "#append_to_file", type: :sandbox do
  shared_context "appending to files" do
    it "appends to file" do
      file = path_factory.call("Gemfile")

      TTY::File.append_to_file(file, "gem 'tty'", verbose: false)

      expect(File.read(file)).to eq([
        "gem 'nokogiri'\n",
        "gem 'rails', '5.0.0'\n",
        "gem 'rack', '>=1.0'\n",
        "gem 'tty'"
      ].join)
    end

    it "appends multiple lines to file" do
      file = path_factory.call("Gemfile")

      TTY::File.append_to_file(file, "gem 'tty'\n", "gem 'rake'", verbose: false)

      expect(File.read(file)).to eq([
        "gem 'nokogiri'\n",
        "gem 'rails', '5.0.0'\n",
        "gem 'rack', '>=1.0'\n",
        "gem 'tty'\n",
        "gem 'rake'"
      ].join)
    end

    it "appends content in a block" do
      file = path_factory.call("Gemfile")

      TTY::File.append_to_file(file, verbose: false) { "gem 'tty'"}

      expect(File.read(file)).to eq([
        "gem 'nokogiri'\n",
        "gem 'rails', '5.0.0'\n",
        "gem 'rack', '>=1.0'\n",
        "gem 'tty'"
      ].join)
    end

    it "doesn't append if already present" do
      file = path_factory.call("Gemfile")

      TTY::File.append_to_file(file, "gem 'rack', '>=1.0'\n", force: false, verbose: false)

      expect(::File.read(file)).to eq([
        "gem 'nokogiri'\n",
        "gem 'rails', '5.0.0'\n",
        "gem 'rack', '>=1.0'\n",
      ].join)
    end

    it "appends safely checking if content already present" do
      file = path_factory.call("Gemfile")

      TTY::File.safe_append_to_file(file, "gem 'rack', '>=1.0'\n", verbose: false)

      expect(::File.read(file)).to eq([
        "gem 'nokogiri'\n",
        "gem 'rails', '5.0.0'\n",
        "gem 'rack', '>=1.0'\n",
      ].join)
    end

    it "appends multiple times by default" do
      file = path_factory.call("Gemfile")

      TTY::File.append_to_file(file, "gem 'tty'\n", verbose: false)
      TTY::File.append_to_file(file, "gem 'tty'\n", verbose: false)

      expect(::File.read(file)).to eq([
        "gem 'nokogiri'\n",
        "gem 'rails', '5.0.0'\n",
        "gem 'rack', '>=1.0'\n",
        "gem 'tty'\n",
        "gem 'tty'\n"
      ].join)
    end

    it "logs action" do
      file = path_factory.call("Gemfile")
      expect {
        TTY::File.add_to_file(file, "gem 'tty'")
      }.to output(/\e\[32mappend\e\[0m.*Gemfile/).to_stdout_from_any_process
    end

    it "logs action without color" do
      file = path_factory.call("Gemfile")
      expect {
        TTY::File.add_to_file(file, "gem 'tty'", color: false)
      }.to output(/\s+append.*Gemfile/).to_stdout_from_any_process
    end
  end

  context "when passed a String instance for the file argument" do
    let(:path_factory) { ->(file) { file } }

    include_context "appending to files"
  end

  context "when passed a Pathname instance for the file argument" do
    let(:path_factory) { ->(file) { Pathname(file) } }

    include_context "appending to files"
  end
end
