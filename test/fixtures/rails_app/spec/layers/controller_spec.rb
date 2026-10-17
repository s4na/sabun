require_relative '../rails_helper'

RSpec.describe CheckoutsController, type: :controller do
  it '価格を描画する' do
    get :show
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<span id="price">1200</span>')
  end
end
