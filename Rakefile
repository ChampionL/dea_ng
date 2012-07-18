# coding: UTF-8

require "rspec/core/rake_task"
require "rspec/core/version"

desc "Run all examples"
RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = %w[--color --format documentation]
end

task :ensure_coding do
  patterns = [
    /Rakefile$/,
    /\.rb$/,
  ]

  files = `git ls-files`.split.select do |file|
    patterns.any? { |e| e.match(file) }
  end

  header = "# coding: UTF-8\n\n"

  files.each do |file|
    content = File.read(file)

    unless content.start_with?(header)
      File.open(file, "w") do |f|
        f.write(header)
        f.write(content)
      end
    end
  end
end
