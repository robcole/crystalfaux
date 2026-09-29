require "../../spec_helper"

private def quad(*points : {Float64, Float64}) : Crystalfaux::Protocol::Page::Quad
  corners = points.to_a.map_with_index { |(x, y), index| {"p#{index + 1}", {x: x, y: y}} }.to_h
  Crystalfaux::Protocol.decode(Crystalfaux::Protocol::Page::Quad, JSON.parse(corners.to_json))
end

private def close_to(point : {Float64, Float64}?, expected : {Float64, Float64}) : Nil
  x, y = point.should_not(be_nil)
  x.should be_close(expected[0], 1e-6)
  y.should be_close(expected[1], 1e-6)
end

describe Crystalfaux::Protocol::Page::Quad do
  describe "#local_point" do
    it "maps a viewport point into an untransformed box" do
      box = quad({50.0, 40.0}, {350.0, 40.0}, {350.0, 240.0}, {50.0, 240.0})

      close_to(box.local_point(150, 90, 300, 200), {100.0, 50.0})
    end

    it "undoes a scale and a rotation" do
      # A 100 x 50 box scaled by 2 and turned 90 degrees clockwise around
      # its top-left corner at (200, 100).
      box = quad({200.0, 100.0}, {200.0, 300.0}, {100.0, 300.0}, {100.0, 100.0})

      close_to(box.local_point(180, 140, 100, 50), {20.0, 10.0})
    end

    it "gives nil for a box without area or with a perspective" do
      flat = quad({0.0, 0.0}, {10.0, 0.0}, {10.0, 0.0}, {0.0, 0.0})
      flat.local_point(5, 0, 10, 10).should be_nil

      perspective = quad({0.0, 0.0}, {100.0, 0.0}, {90.0, 50.0}, {10.0, 60.0})
      perspective.local_point(50, 20, 100, 50).should be_nil
    end
  end
end
