# frozen_string_literal: true

require "spec_helper"
require "dependabot/utils/java_script/requirement"
require "dependabot/utils/java_script/version"

RSpec.describe Dependabot::Utils::JavaScript::Requirement do
  subject(:requirement) { described_class.new(requirement_string) }
  let(:requirement_string) { ">=1.0.0" }

  describe ".new" do
    it { is_expected.to be_a(described_class) }

    context "with an exact version specified" do
      let(:requirement_string) { "1.0.0" }
      it { is_expected.to eq(described_class.new("1.0.0")) }
    end

    context "with a dist tag" do
      let(:requirement_string) { "next" }
      it "raises a bad requirement error" do
        expect { requirement }.
          to raise_error(Gem::Requirement::BadRequirementError)
      end
    end

    context "with a caret version specified" do
      let(:requirement_string) { "^1.0.0" }
      it { is_expected.to eq(described_class.new(">= 1.0.0", "< 2.0.0.a")) }

      context "for two digits" do
        let(:requirement_string) { "^1.2" }
        it { is_expected.to eq(described_class.new(">= 1.2", "< 2.0.0.a")) }
      end

      context "with a pre-1.0.0 dependency" do
        let(:requirement_string) { "^0.2.3" }
        it { is_expected.to eq(described_class.new(">= 0.2.3", "< 0.3.0.a")) }
      end
    end

    context "with a ~ version specified" do
      let(:requirement_string) { "~1.5.1" }
      it { is_expected.to eq(Gem::Requirement.new("~> 1.5.1")) }
    end

    context "with a hyphen range specified" do
      let(:requirement_string) { "1.0.0 - 1.5.0" }
      it { is_expected.to eq(Gem::Requirement.new(["<= 1.5.0", ">= 1.0.0"])) }
    end

    context "with a ~> version specified" do
      let(:requirement_string) { "~>1.5.1" }
      it { is_expected.to eq(Gem::Requirement.new("~> 1.5.1")) }

      context "specified to 2 places" do
        let(:requirement_string) { "~> 0.5" }
        it { is_expected.to eq(Gem::Requirement.new("~> 0.5.0")) }
      end
    end

    context "with only a *" do
      let(:requirement_string) { "*" }
      it { is_expected.to eq(Gem::Requirement.new(">= 0")) }
    end

    context "with a *" do
      let(:requirement_string) { "1.*" }
      it { is_expected.to eq(Gem::Requirement.new("~> 1.0")) }
    end

    context "with an x" do
      let(:requirement_string) { "^1.1.x" }
      it { is_expected.to eq(described_class.new(">= 1.1", "< 2.0.0.a")) }
    end

    context "with a 'v' prefix" do
      let(:requirement_string) { ">=v1.0.0" }
      it { is_expected.to eq(described_class.new(">= v1.0.0")) }
    end
  end

  describe "#requirements_array" do
    subject { described_class.requirements_array(requirement_string) }

    context "with multiple intersecting requirements" do
      let(:requirement_string) { ">=1.0.0 <=1.5.0" }
      it { is_expected.to eq([Gem::Requirement.new("<= 1.5.0", ">= 1.0.0")]) }

      context "separated by &&" do
        let(:requirement_string) { ">=1.0.0 && <=1.5.0" }
        it { is_expected.to eq([Gem::Requirement.new("<= 1.5.0", ">= 1.0.0")]) }
      end
    end

    context "with multiple optional requirements" do
      let(:requirement_string) { "^1.0.0 || ^2.0.0" }
      it do
        is_expected.to match_array(
          [
            Gem::Requirement.new(">= 1.0.0", "< 2.0.0.a"),
            Gem::Requirement.new(">= 2.0.0", "< 3.0.0.a")
          ]
        )
      end
    end

    context "with parentheses that do nothing" do
      let(:requirement_string) { "(^1.0.0 || ^2.0.0)" }
      it do
        is_expected.to match_array(
          [
            Gem::Requirement.new(">= 1.0.0", "< 2.0.0.a"),
            Gem::Requirement.new(">= 2.0.0", "< 3.0.0.a")
          ]
        )
      end
    end
  end

  describe "#satisfied_by?" do
    subject { requirement.satisfied_by?(version) }

    context "with a Gem::Version" do
      context "for the current version" do
        let(:version) { Gem::Version.new("1.0.0") }
        it { is_expected.to eq(true) }

        context "when the requirement includes a v prefix" do
          let(:requirement_string) { ">=v1.0.0" }
          it { is_expected.to eq(true) }
        end
      end

      context "for an out-of-range version" do
        let(:version) { Gem::Version.new("0.9.0") }
        it { is_expected.to eq(false) }
      end
    end

    context "with a Utils::JavaScript::Version" do
      let(:version) do
        Dependabot::Utils::JavaScript::Version.new(version_string)
      end

      context "for the current version" do
        let(:version_string) { "1.0.0" }
        it { is_expected.to eq(true) }

        context "that includes a 'v' prefix" do
          let(:version_string) { "v1.0.0" }
          it { is_expected.to eq(true) }
        end
      end
    end
  end
end
