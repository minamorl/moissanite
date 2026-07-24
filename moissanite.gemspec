# frozen_string_literal: true

require_relative 'lib/moissanite/version'

Gem::Specification.new do |spec|
  spec.name = 'moissanite'
  spec.version = Moissanite::VERSION
  spec.summary = 'Native-level kernels written as Ruby data'
  spec.description = 'Write native-level numeric kernels as inspectable Ruby expression trees. ' \
                     'A pure-Ruby oracle defines the semantics; FFI-driven backends JIT the same ' \
                     'tree through the system C toolchain. No custom compiler, runtime specialization included.'
  spec.authors = ['minamorl']
  spec.email = ['minamorl@users.noreply.github.com']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/minamorl/moissanite'

  spec.required_ruby_version = '>= 3.2'
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir[
    'lib/**/*.rb',
    'README.md',
    'LICENSE'
  ]
  spec.require_paths = ['lib']

  # 生メモリ・dlopen・関数ポインタの床。Ruby 3.5 以降 bundled gem になる
  # ため明示依存にする (それ以前は標準添付と同居して無害)。
  spec.add_dependency 'fiddle'
end
