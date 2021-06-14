# frozen_string_literal: true

require_relative 'lib/solidus_square/version'

Gem::Specification.new do |spec|
  spec.name = 'solidus_square'
  spec.version = SolidusSquare::VERSION
  spec.authors = ['Z-Rho In']
  spec.email = 'keith@z-rho.in'

  spec.summary = 'Square Payment Method for Solidus'
  spec.description = 'Square Payment Method for Solidus'
  spec.homepage = 'https://github.com/z-rho-in/solidus_square'
  spec.license = 'BSD-3'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/z-rho-in/solidus_square'

  spec.required_ruby_version = '>= 2.4.0'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  files = Dir.chdir(__dir__) { `git ls-files -z`.split("\x0") }

  spec.files = files.grep_v(%r{^(test|spec|features)/})
  spec.test_files = files.grep(%r{^(test|spec|features)/})
  spec.bindir = "exe"
  spec.executables = files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency 'solidus_core', ['>= 2.3', '< 4']
  spec.add_dependency 'solidus_support', '~> 0.8'
  spec.add_dependency 'square.rb', '~> 11'
  spec.add_dependency 'activemerchant', '>= 1.105'

  spec.add_development_dependency 'solidus_dev_support', '~> 2.3'
end
