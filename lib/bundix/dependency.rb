require "bundler"

class Dependency < Bundler::Dependency
  def initialize(name, version, options = {}, &blk)
    super(name, version, options, &blk)
    @bundix_version = version
  end

  attr_reader :version
end

def parse_gemfiles(gemfile, lockfile)
  lock = Bundler::LockfileParser.new(File.read(lockfile))
  definition = Bundler::Definition.build(gemfile, lockfile, false)

  deps = {}

  definition.dependencies.each do |dep|
    deps[dep.name] = dep
  end

  lock.specs.each do |spec|
    deps[spec.name] ||= Dependency.new(spec.name, nil, {})
  end

  begin
    changed = false
    lock.specs.each do |spec|
      as_dep = deps.fetch(spec.name)

      spec.dependencies.each do |dep|
        cached = deps.fetch(dep.name) do |name|
          if name != "bundler"
            raise KeyError, "Gem dependency '#{name}' not specified in #{lockfile}"
          end
          deps[name] = Dependency.new(name, lock.bundler_version, {})
        end

        if !((as_dep.groups - cached.groups) - [:default]).empty? or !(as_dep.platforms - cached.platforms).empty?
          changed = true
          deps[cached.name] = (Dependency.new(cached.name, nil, {
            "group" => as_dep.groups | cached.groups,
            "platforms" => as_dep.platforms | cached.platforms,
          }))

          cc = deps[cached.name]
        end
      end
    end
  end while changed

  return deps, lock
end
