# frozen_string_literal: true

class UsersController < ApplicationController
  def index
    @users = User.where("name = '#{params[:name]}'")
  end
end
