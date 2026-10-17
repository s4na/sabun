Rails.application.routes.draw do
  get '/health', to: proc { [200, { 'content-type' => 'text/plain' }, ['ok']] }
  get '/checkout', to: 'checkouts#show'
  get '/shipping', to: 'shipping#show'
  post '/orders', to: 'orders#create'
  get '/orders/:id', to: 'orders#show'
  post '/__fixture__/reset', to: 'fixture#reset'
end
