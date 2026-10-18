require_relative '../rails_helper'

RSpec.describe '注文', type: :request do
  it 'inlineジョブのDB更新を画面に反映する' do
    post '/orders'
    expect(response).to have_http_status(:redirect)
    follow_redirect!
    expect(response.body).to include('<span id="status">paid</span>')
    expect(Order.last.status).to eq('paid')
  end
end
