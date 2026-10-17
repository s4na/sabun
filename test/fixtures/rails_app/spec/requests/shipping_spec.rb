require_relative '../rails_helper'

RSpec.describe '配送', type: :request do
  it '購入価格と独立した配送方法を返す' do
    get '/shipping'
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('standard')
  end
end
