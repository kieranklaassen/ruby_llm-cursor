# frozen_string_literal: true

require_relative "lib/ruby_llm/cursor/version"

Gem::Specification.new do |spec|
  spec.name = "ruby_llm-cursor"
  spec.version = RubyLLM::Cursor::VERSION
  spec.authors = ["Kieran Klaassen"]
  spec.email = ["kieranklaassen@gmail.com"]

  spec.summary = "Chat with Cursor's coding agent through RubyLLM"
  spec.description = "Registers a :cursor provider for RubyLLM that drives the local cursor-agent CLI. " \
                     "Get plain-text answers via chat.ask, stream agent events, and hold multi-turn " \
                     "conversations backed by a persistent Cursor agent session."
  spec.homepage = "https://github.com/kieranklaassen/ruby_llm-cursor"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb"] + ["README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "ruby_llm", "~> 1.15"
end
