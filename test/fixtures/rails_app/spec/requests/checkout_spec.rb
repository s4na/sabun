require_relative '../rails_helper'

RSpec.describe '購入画面', type: :request do
  it '価格・タイトル・起動時に計算した値を描画する' do
    get '/checkout'
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<h1>Checkout</h1>')
    expect(response.body).to include('<span id="price">1200</span>')
    expect(response.body).to include('<span id="banner">ready</span>')
  end
end
