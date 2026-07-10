# frozen_string_literal: true

Rails.application.routes.draw do
  get "users", to: "users#index"
end
