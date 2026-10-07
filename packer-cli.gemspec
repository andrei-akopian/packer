# frozen_string_literal: true

require_relative "lib/packer"

Gem::Specification.new do |spec|
  spec.name = "packer-cli"
  spec.version = Packer::VERSION
  spec.summary = "Compress, encrypt, and timestamp archives with system tools"
  spec.description = "A small CLI utility for archive compression, encryption, extraction, and detached timestamp proofs."
  spec.authors = ["andrei-akopian"]
  spec.homepage = "https://github.com/andrei-akopian/packer"
  spec.required_ruby_version = ">= 2.7"
  spec.files = Dir["lib/**/*.rb", "exe/*", "config/*.yml", "test/**/*.sh"] + ["README.md"]
  spec.bindir = "exe"
  spec.executables = ["packer"]
  spec.require_paths = ["lib"]
end
