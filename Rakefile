# frozen_string_literal: true

require 'rake/testtask'
require 'rubocop/rake_task'

Rake::TestTask.new(:test) do |task|
  task.libs << 'test'
  task.pattern = 'test/**/*_test.rb'
end

RuboCop::RakeTask.new(:rubocop)

desc 'Run the benchmark suite (builds nothing; JIT happens at runtime)'
task :bench do
  ruby 'bench/bench.rb'
end

task lint: :rubocop
task default: %i[test rubocop]
