module Forecast
  class CanvasController < BaseController
    def show
      @workspace = Forecast::Workspace.new(family: @family)
      @canvas_payload = Forecast::CanvasReadModel.new(@workspace).payload
    end
  end
end
