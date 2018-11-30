# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/file_updaters/go/modules/go_mod_updater"

RSpec.describe Dependabot::FileUpdaters::Go::Modules::GoModUpdater do
  let(:updater) do
    described_class.new(
      go_mod: go_mod,
      go_sum: go_sum,
      dependencies: [dependency],
      credentials: [{
        "type" => "git_source",
        "host" => "github.com",
        "username" => "x-access-token",
        "password" => "token"
      }]
    )
  end

  let(:go_sum) { nil }
  let(:go_mod) do
    Dependabot::DependencyFile.new(name: "go.mod", content: go_mod_body)
  end
  let(:go_mod_body) { fixture("go", "go_mods", go_mod_fixture_name) }
  let(:go_mod_fixture_name) { "go.mod" }

  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: dependency_version,
      requirements: requirements,
      previous_version: dependency_previous_version,
      previous_requirements: previous_requirements,
      package_manager: "dep"
    )
  end

  describe "#updated_go_mod_content" do
    subject(:updated_go_mod_content) { updater.updated_go_mod_content }

    context "for a top level dependency" do
      let(:dependency_name) { "rsc.io/quote" }
      let(:dependency_version) { "v1.4.0" }
      let(:dependency_previous_version) { "v1.4.0" }
      let(:requirements) { previous_requirements }
      let(:previous_requirements) do
        [{
          file: "go.mod",
          requirement: "v1.4.0",
          groups: [],
          source: {
            type: "default",
            source: "rsc.io/quote"
          }
        }]
      end

      context "if no files have changed" do
        it { is_expected.to eq(go_mod.content) }
      end

      context "when the requirement has changed" do
        let(:dependency_version) { "v1.5.2" }
        let(:requirements) do
          [{
            file: "go.mod",
            requirement: "v1.5.2",
            groups: [],
            source: {
              type: "default",
              source: "rsc.io/quote"
            }
          }]
        end

        it { is_expected.to include(%(rsc.io/quote v1.5.2\n)) }

        context "with a go.sum" do
          let(:go_sum) do
            Dependabot::DependencyFile.new(name: "go.sum", content: go_sum_body)
          end
          let(:go_sum_body) { fixture("go", "go_mods", go_sum_fixture_name) }
          let(:go_sum_fixture_name) { "go.sum" }
          subject(:updated_go_sum_content) { updater.updated_go_sum_content }

          it "adds new entries to the go.sum" do
            is_expected.
              to include(%(rsc.io/quote v1.5.2 h1:))
            is_expected.
              to include(%(rsc.io/quote v1.5.2/go.mod h1:))
          end

          # This happens via `go mod tidy`, which we currently can't run, as we
          # need to the whole source repo
          pending "removes old entries from the go.sum" do
            is_expected.
              to include(%(rsc.io/quote v1.4.0 h1:))
            is_expected.
              to_not include(%(rsc.io/quote v1.4.0/go.mod h1:))
          end
        end
      end

      context "when it has become indirect" do
        let(:dependency_version) { "v1.5.2" }
        let(:requirements) do
          []
        end

        it { is_expected.to include(%(rsc.io/quote v1.5.2 // indirect\n)) }
      end
    end

    context "for an explicit indirect dependency" do
      let(:dependency_name) { "github.com/mattn/go-colorable" }
      let(:dependency_version) { "v0.0.9" }
      let(:dependency_previous_version) { "v0.0.9" }
      let(:requirements) { previous_requirements }
      let(:previous_requirements) { [] }

      context "if no files have changed" do
        it { is_expected.to eq(go_mod.content) }
      end

      context "when the version has changed" do
        let(:dependency_version) { "v0.1.0" }

        it do
          is_expected.
            to include(%(github.com/mattn/go-colorable v0.1.0 // indirect\n))
        end
      end
    end

    context "for an implicit (vgo) indirect dependency" do
      let(:dependency_name) { "rsc.io/sampler" }
      let(:dependency_version) { "v1.2.0" }
      let(:dependency_previous_version) { "v1.2.0" }
      let(:requirements) { previous_requirements }
      let(:previous_requirements) { [] }

      context "when the version has changed" do
        let(:dependency_version) { "v1.3.0" }

        it do
          is_expected.
            to include(%(rsc.io/sampler v1.3.0 // indirect\n))
        end
      end
    end
  end
end
