require "./spec_helper"

private def args(json : String) : Marten::MCP::Args
  Marten::MCP::Args.new(JSON.parse(json))
end

describe Marten::MCP::Args do
  describe "#string?" do
    it "returns the value when the key is present" do
      args(%({"name":"hello"})).string?("name").should eq "hello"
    end

    it "returns nil when the key is absent" do
      args(%({})).string?("name").should be_nil
    end

    it "returns nil for a blank string, via presence" do
      args(%({"name":"   "})).string?("name").should be_nil
    end

    it "raises Invalid naming the field for a non-string value" do
      error = expect_raises(Marten::MCP::Args::Invalid) { args(%({"name":5})).string?("name") }
      error.field.should eq "name"
    end
  end

  describe "#string" do
    it "returns the value when present" do
      args(%({"name":"hello"})).string("name").should eq "hello"
    end

    it "raises Invalid naming the field when the key is missing" do
      error = expect_raises(Marten::MCP::Args::Invalid) { args(%({})).string("name") }
      error.field.should eq "name"
    end

    it "raises Invalid when the value is blank, same as missing" do
      expect_raises(Marten::MCP::Args::Invalid) { args(%({"name":""})).string("name") }
    end
  end

  describe "#bool?" do
    it "returns the value when the key is present" do
      args(%({"active":true})).bool?("active").should eq true
      args(%({"active":false})).bool?("active").should eq false
    end

    it "returns nil when the key is absent" do
      args(%({})).bool?("active").should be_nil
    end

    it "raises Invalid naming the field for a non-boolean value" do
      error = expect_raises(Marten::MCP::Args::Invalid) { args(%({"active":"yes"})).bool?("active") }
      error.field.should eq "active"
    end
  end

  describe "#int?" do
    it "returns the value when the key is present" do
      args(%({"limit":5})).int?("limit").should eq 5
    end

    it "returns nil when the key is absent" do
      args(%({})).int?("limit").should be_nil
    end

    it "raises Invalid naming the field for a non-integer value" do
      error = expect_raises(Marten::MCP::Args::Invalid) { args(%({"limit":"five"})).int?("limit") }
      error.field.should eq "limit"
    end

    # `.to_i32` is a checked conversion that raises OverflowError; #int? must
    # bounds-check first so this fails the same named-field Invalid way as
    # any other malformed argument, not as an uncaught exception.
    it "raises Invalid, not OverflowError, for a value beyond Int32" do
      error = expect_raises(Marten::MCP::Args::Invalid) { args(%({"limit":99999999999})).int?("limit") }
      error.field.should eq "limit"
    end
  end

  describe "#int" do
    it "clamps a value above max down to max" do
      args(%({"limit":500})).int("limit", 10, 100).should eq 100
    end

    it "floors a value below 1 at 1" do
      args(%({"limit":-5})).int("limit", 10, 100).should eq 1
    end

    it "applies the default when the key is absent" do
      args(%({})).int("limit", 10, 100).should eq 10
    end

    it "returns the value unchanged when within bounds" do
      args(%({"limit":42})).int("limit", 10, 100).should eq 42
    end
  end

  describe "a non-object payload" do
    it "behaves as no arguments at all" do
      scalar = Marten::MCP::Args.new(JSON.parse("5"))
      scalar.string?("name").should be_nil
      scalar.int("limit", 10, 100).should eq 10
    end
  end
end
