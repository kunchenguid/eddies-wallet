#!/usr/bin/env ruby
# frozen_string_literal: true

# Deterministic release-please lineage checks for Eddie's Wallet.
# Credential-free and network-free: reads committed files (and optional local
# git tags / fixture tag lists). Used by test/release-checks.sh for the live
# tree and for colocated pre-/post-first-release counterfactual fixtures.

require "json"

module ReleaseLineage
  SEMVER = /\A\d+\.\d+\.\d+\z/
  CHANGELOG_HEADING = /^## \[?(\d+\.\d+\.\d+)\]?(?:\s|\(|$)/
  TAG_VERSION = /\Aeddies-wallet-v(\d+\.\d+\.\d+)\z/
  COMPONENT = "eddies-wallet"
  REQUIRED_INITIAL = "0.1.0"
  PRE_FIRST_SEED = "0.0.0"

  module_function

  def version_key(version)
    version.split(".").map(&:to_i)
  end

  def initial_release_version(initial)
    initial || "1.0.0"
  end

  # Faithful release-please 17.x first-proposal path when the seed is 0.0.0
  # and no matching tag exists: manifest.js skips 0.0.0, so no latestRelease
  # is synthesized.
  def first_proposal(seed, initial)
    return initial_release_version(initial) if seed == PRE_FIRST_SEED

    "not-initial-path"
  end

  def changelog_versions(text)
    versions = []
    text.to_s.each_line do |line|
      version = line[CHANGELOG_HEADING, 1]
      versions << version if version
    end
    versions.uniq
  end

  def tag_versions(tag_names)
    versions = []
    Array(tag_names).each do |tag|
      version = tag.to_s[TAG_VERSION, 1]
      versions << version if version
    end
    versions.uniq
  end

  def latest_version(versions)
    versions.max_by { |version| version_key(version) }
  end

  def load_tree(dir, tags: nil)
    dir = File.expand_path(dir)
    config = JSON.parse(File.read(File.join(dir, "release-please-config.json")))
    manifest = JSON.parse(File.read(File.join(dir, ".release-please-manifest.json")))
    version_file = File.read(File.join(dir, "version.txt")).strip
    changelog = File.exist?(File.join(dir, "CHANGELOG.md")) ? File.read(File.join(dir, "CHANGELOG.md")) : ""
    if tags.nil?
      tags_path = File.join(dir, "tags.txt")
      tags = File.exist?(tags_path) ? File.read(tags_path).lines.map(&:strip).reject(&:empty?) : []
    end
    {
      config: config,
      manifest: manifest,
      version_file: version_file,
      changelog: changelog,
      tags: tags
    }
  end

  def live_tags(repo_root)
    Dir.chdir(repo_root) do
      `git tag -l 'eddies-wallet-v*' 2>/dev/null`.lines.map(&:strip).reject(&:empty?)
    end
  rescue StandardError
    []
  end

  def validate_tree(dir, tags: nil, label: dir)
    data = load_tree(dir, tags: tags)
    validate(
      seed: data[:manifest].fetch("."),
      version_file: data[:version_file],
      config: data[:config],
      changelog_text: data[:changelog],
      tag_names: data[:tags],
      label: label
    )
  end

  def validate(seed:, version_file:, config:, changelog_text:, tag_names:, label: "tree")
    errors = []
    pkg = config.fetch("packages").fetch(".")
    initial = pkg["initial-version"] || config["initial-version"]
    header = config["pull-request-header"].to_s
    component = pkg.fetch("component")

    errors << "#{label}: version.txt (#{version_file}) must match manifest seed (#{seed})" unless version_file == seed
    errors << "#{label}: initial-version must be #{REQUIRED_INITIAL} (got #{initial.inspect})" unless initial == REQUIRED_INITIAL
    errors << "#{label}: component must be #{COMPONENT} (got #{component})" unless component == COMPONENT
    unless header.include?("Only the captain merges it") && header.include?("TestFlight")
      errors << "#{label}: captain-only pull-request-header must remain set"
    end

    lineage = (changelog_versions(changelog_text) + tag_versions(tag_names)).uniq
    latest = latest_version(lineage)

    if seed == PRE_FIRST_SEED
      unless lineage.empty?
        errors << "#{label}: pre-first-release seed #{PRE_FIRST_SEED} is invalid once released lineage exists (#{lineage.sort_by { |v| version_key(v) }.join(", ")})"
      end
      proposed = first_proposal(seed, initial)
      errors << "#{label}: first proposal must be #{REQUIRED_INITIAL} (got #{proposed})" unless proposed == REQUIRED_INITIAL
      broken = first_proposal(seed, nil)
      errors << "#{label}: missing initial-version must still reproduce the 1.0.0 default (got #{broken})" unless broken == "1.0.0"
    else
      unless seed.match?(SEMVER)
        errors << "#{label}: advanced manifest/version seed must be X.Y.Z semver (got #{seed.inspect})"
      end
      if lineage.empty?
        errors << "#{label}: advanced manifest/version seed #{seed} has no released lineage evidence (CHANGELOG heading or eddies-wallet-v* tag)"
      elsif latest != seed
        ordered = lineage.sort_by { |version| version_key(version) }
        errors << "#{label}: advanced manifest/version seed #{seed} must match latest released lineage #{latest} (known: #{ordered.join(", ")})"
      end
    end

    errors
  end

  def self_test!
    failures = []

    # Pure first-proposal semantics (always enforced; independent of live seed).
    unless first_proposal("0.0.0", "0.1.0") == "0.1.0"
      failures << "pre-first proposal with initial-version 0.1.0 must be 0.1.0"
    end
    unless first_proposal("0.0.0", nil) == "1.0.0"
      failures << "pre-first proposal without initial-version must default to 1.0.0"
    end
    unless first_proposal("0.1.0", "0.1.0") == "not-initial-path"
      failures << "post-first seed must not take the initial-version proposal path"
    end

    base_config = {
      "initial-version" => "0.1.0",
      "pull-request-header" => "Merging this release PR cuts the release tag and uploads Eddie's Wallet to TestFlight. Only the captain merges it.",
      "packages" => { "." => { "component" => "eddies-wallet" } }
    }

    pre = validate(
      seed: "0.0.0",
      version_file: "0.0.0",
      config: base_config,
      changelog_text: "# Changelog\n",
      tag_names: [],
      label: "self-test pre-first"
    )
    failures.concat(pre.map { |error| "expected pass: #{error}" })

    post = validate(
      seed: "0.1.0",
      version_file: "0.1.0",
      config: base_config,
      changelog_text: "# Changelog\n\n## 0.1.0 (2026-07-28)\n",
      tag_names: ["eddies-wallet-v0.1.0"],
      label: "self-test post-first"
    )
    failures.concat(post.map { |error| "expected pass: #{error}" })

    mismatched = validate(
      seed: "9.9.9",
      version_file: "9.9.9",
      config: base_config,
      changelog_text: "# Changelog\n\n## 0.1.0 (2026-07-28)\n",
      tag_names: ["eddies-wallet-v0.1.0"],
      label: "self-test mismatched"
    )
    unless mismatched.any? { |error| error.include?("must match latest released lineage") }
      failures << "mismatched advanced seed must fail lineage check (got: #{mismatched.inspect})"
    end

    unjustified = validate(
      seed: "0.1.0",
      version_file: "0.1.0",
      config: base_config,
      changelog_text: "# Changelog\n",
      tag_names: [],
      label: "self-test unjustified"
    )
    unless unjustified.any? { |error| error.include?("no released lineage evidence") }
      failures << "advanced seed without lineage evidence must fail (got: #{unjustified.inspect})"
    end

    rolled_back = validate(
      seed: "0.0.0",
      version_file: "0.0.0",
      config: base_config,
      changelog_text: "# Changelog\n\n## 0.1.0 (2026-07-28)\n",
      tag_names: ["eddies-wallet-v0.1.0"],
      label: "self-test rolled-back"
    )
    unless rolled_back.any? { |error| error.include?("pre-first-release seed") }
      failures << "0.0.0 seed after releases exist must fail (got: #{rolled_back.inspect})"
    end

    stale = validate(
      seed: "0.1.0",
      version_file: "0.1.0",
      config: base_config,
      changelog_text: "# Changelog\n\n## 0.2.0 (2026-08-01)\n\n## 0.1.0 (2026-07-28)\n",
      tag_names: %w[eddies-wallet-v0.1.0 eddies-wallet-v0.2.0],
      label: "self-test stale"
    )
    unless stale.any? { |error| error.include?("must match latest released lineage 0.2.0") }
      failures << "stale advanced seed must fail (got: #{stale.inspect})"
    end

    failures
  end
end

if $PROGRAM_NAME == __FILE__
  mode = ARGV.shift
  case mode
  when "--self-test"
    failures = ReleaseLineage.self_test!
    if failures.empty?
      puts "ok"
      exit 0
    end
    warn failures.join("\n")
    exit 1
  when "--live"
    root = ARGV.shift or abort "usage: validate.rb --live REPO_ROOT"
    errors = ReleaseLineage.validate_tree(root, tags: ReleaseLineage.live_tags(root), label: "live")
    if errors.empty?
      seed = JSON.parse(File.read(File.join(root, ".release-please-manifest.json"))).fetch(".")
      state = seed == ReleaseLineage::PRE_FIRST_SEED ? "pre-first-release" : "post-first-release"
      puts "ok:#{state}:#{seed}"
      exit 0
    end
    warn errors.join("\n")
    exit 1
  when "--fixture"
    dir = ARGV.shift or abort "usage: validate.rb --fixture FIXTURE_DIR"
    label = File.basename(dir)
    errors = ReleaseLineage.validate_tree(dir, label: label)
    expect_fail = File.exist?(File.join(dir, "expect-fail"))
    if expect_fail
      if errors.empty?
        warn "#{label}: expected lineage validation to fail, but it passed"
        exit 1
      end
      puts "ok:expected-fail:#{label}"
      exit 0
    end
    if errors.empty?
      puts "ok:#{label}"
      exit 0
    end
    warn errors.join("\n")
    exit 1
  else
    warn "usage: validate.rb --self-test | --live REPO_ROOT | --fixture FIXTURE_DIR"
    exit 2
  end
end
