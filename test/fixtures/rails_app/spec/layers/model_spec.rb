require_relative '../rails_helper'

RSpec.describe Order, type: :model do
  it '未設定のstatusを拒否する' do
    expect(Order.new(status: nil)).not_to be_valid
  end

  it 'paid?は支払い済みの注文だけtrueを返す' do
    expect(Order.new(status: 'paid').paid?).to be(true)
    expect(Order.new(status: 'pending').paid?).to be(false)
  end
end
