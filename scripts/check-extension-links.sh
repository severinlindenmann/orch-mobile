#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Ruby's standard-library YAML parser avoids adding a build dependency.
ruby -ryaml -rjson -ropen3 <<'RUBY'
project = YAML.load_file('project.yml')
allowed = { 'OrchNotify' => %w[OrchPush OrchProtocol], 'OrchShare' => %w[OrchUI] }
# Keep compiler caches in the worktree; manifest evaluation needs no nested sandbox
# (there are no remote dependencies or build plugins).
ENV['CLANG_MODULE_CACHE_PATH'] ||= File.expand_path('.build/clang-cache')
manifest, status = Open3.capture2('swift', 'package', '--disable-sandbox', '--package-path', 'OrchKit', 'dump-package')
abort 'Cannot read OrchKit manifest' unless status.success?
package = JSON.parse(manifest)
abort 'Third-party package dependencies are forbidden' unless package.fetch('dependencies').empty?
products = package.fetch('products').to_h { |p| [p.fetch('name'), p.fetch('targets')] }
targets = package.fetch('targets').to_h { |t| [t.fetch('name'), t] }
allowed.each do |name, permitted|
  target = project.fetch('targets').fetch(name)
  abort "#{name}: extension API safety is disabled" unless target.fetch('settings').fetch('base').fetch('APPLICATION_EXTENSION_API_ONLY') == true
  roots = target.fetch('dependencies').flat_map do |dep|
    abort "#{name}: unexpected dependency #{dep}" unless dep['package'] == 'OrchKit' && (dep.keys - %w[package product products]).empty?
    names = dep['products'] || [dep.fetch('product')]
    names.flat_map do |product|
      abort "#{name}: forbidden product #{product}" unless permitted.include?(product)
      products.fetch(product)
    end
  end
  abort "#{name}: missing required product" unless roots.include?(name == 'OrchNotify' ? 'OrchPush' : 'OrchUI')
  visited = []
  visit = lambda do |module_name|
    return if visited.include?(module_name)
    abort "#{name}: forbidden transitive module #{module_name}" unless permitted.include?(module_name)
    visited << module_name
    module_target = targets.fetch(module_name)
    flags = module_target.fetch('settings').flat_map { |s| s.dig('kind', 'unsafeFlags', '_0') || [] }
    abort "#{module_name}: missing -application-extension" unless flags.include?('-application-extension')
    module_target.fetch('dependencies').each do |dep|
      entry = dep['byName'] || dep['target']
      abort "Unexpected external dependency #{dep}" unless entry
      visit.call(entry.first)
    end
  end
  roots.each { |r| visit.call(r) }
  # Also catch undeclared imports, even before a build happens.
  visited.each do |module_name|
    Dir["OrchKit/Sources/#{module_name}/**/*.swift"].each do |file|
      File.read(file).scan(/\bimport\s+(Orch\w+)/).flatten.each do |imported|
        abort "#{name}: forbidden import #{imported} in #{file}" unless permitted.include?(imported)
      end
    end
  end
  Array(target.fetch('sources')).each do |source|
    path = source.is_a?(Hash) ? source.fetch('path') : source
    Dir["#{path}/**/*.swift"].each do |file|
      File.read(file).scan(/\bimport\s+(Orch\w+)/).flatten.each do |imported|
        abort "#{name}: forbidden import #{imported} in #{file}" unless permitted.include?(imported)
      end
    end
  end
  puts "#{name}: allowed dependency closure #{visited.sort.join(', ')}"
end
puts 'Extension links OK'
RUBY
