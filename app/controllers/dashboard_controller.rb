class DashboardController < ApplicationController
  before_action :load_form_references, only: [:index]

  def index
  end

  private

  def load_form_references
  end
end
