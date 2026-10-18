# sabun

Ruby/Rails と Playwright E2E の差分テスト選択gemです。**変更に影響しない根拠があるテストだけを省略し、判断できない変更では全件実行します。**

**状態: v0.1.0（初期実装）。** 実RailsとChromiumを使うテスト用fixtureを同梱し、全件実行との回帰検出の一致と、無関係なテストの省略を品質ゲートで検証します。あらゆるアプリの検出率を保証するものではないため、導入先でも最初はshadow modeで確認してください。

## 対応する機能

- RSpec: Ruby Coverageの行・メソッド実行情報をspecファイル単位で記録。request specを実Railsで検証
- Playwright: テストファイル×project単位で、専用Rails workerの実行情報を記録
- Gitのbaseline commitとHEADの変更差分を取得し、Prismで既存メソッド本体だけの変更を判定
- メソッド本体のみの変更は実行依存で選択。それ以外の構造・設定・資産・新規ファイル変更は全件へフォールバック
- 未観測テスト・不完全なマップ・実行条件不一致を省略しない
- `doctor` / `record` / `plan` / `explain` / `run` のCLI

## インストール

```ruby
# Gemfile
gem 'sabun', git: 'https://github.com/s4na/sabun', require: false
```

または `gem build sabun.gemspec` でローカルgemを生成します。Prismは実行時依存です。

アプリのルートに `sabun.json` を作成します。

```json
{
  "environment_variables": [],
  "suites": [
    {
      "id": "rspec",
      "kind": "rspec",
      "glob": "spec/**/*_spec.rb",
      "command": ["bundle", "exec", "rspec"]
    }
  ]
}
```

`command` はshellを使わず配列で実行されます。全件記録ではテスト全体を実行するコマンドにしてください。CIで保護したいすべてのテストスイートを登録します。

```bash
bundle exec sabun doctor
bundle exec sabun record --all --out tmp/sabun/baseline.json
bundle exec sabun plan --baseline tmp/sabun/baseline.json --out tmp/sabun/plan.json
bundle exec sabun explain --plan tmp/sabun/plan.json
bundle exec sabun run --plan tmp/sabun/plan.json
```

初期導入時は `plan` と `explain` で選択内容を記録し、**CIは従来どおり全件実行**してください。テスト漏れの検証後にのみ `run` に切り替えます。

`tmp/sabun` はgitignoreしてください。記録・計画・実行では、未追跡ファイルも含めて作業ツリーがクリーンである必要があります。baselineは成功した全件実行から作り、作成コミットと環境fingerprintを保存します。実行中にHEAD・追跡ファイル・設定が変わった場合は保存を拒否し、既存のbaselineを残します。選択実行からbaselineを増分更新することはありません。

### 実行条件の登録

Feature Flag、localeなどの環境変数で結果が変わる場合は、`environment_variables` に変数名を登録してください。例: `"environment_variables": ["NEW_CHECKOUT", "APP_LOCALE"]`。設定全体と宣言した値をfingerprintに含め、変更時は過去の依存関係でテストを省略しません。値そのものはマップに保存しません。

外部のFlagサービスやテストデータなど、環境変数だけで表せない条件は`SABUN_ENV_KEY`にその条件のバージョンを設定し、変更に合わせて更新してください。宣言していない外部入力や、Git管理外の実行コードの変更を自動検出する仕組みではありません。

## Playwright E2E

同梱の `playwright/sabun.js` と `playwright/reporter.js` をテスト側プロジェクトにコピーするか参照してください。すべての対象テストで同梱の `test` をimportします。

```js
// e2e/orders.spec.js
const { test, expect } = require('../playwright/sabun');
test('注文画面', async ({ page }) => {
  await page.goto('http://127.0.0.1:3100/orders');
  await expect(page.locator('h1')).toBeVisible();
});
```

```js
// playwright.config.js
module.exports = {
  reporter: [['./playwright/reporter.js']],
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }]
};
```

```json
{
  "environment_variables": [],
  "suites": [
    {
      "id": "e2e",
      "kind": "playwright",
      "glob": "e2e/**/*.spec.js",
      "projects": ["chromium"],
      "command": ["npx", "playwright", "test"]
    }
  ]
}
```

Railsアプリ側では、テスト専用のサーバーを **Playwright workerごとに分離**します。Ruby起動時に `RUBYOPT=-rsabun/e2e/boot` を設定し、Railsのテスト環境で先頭のRack middlewareとして追加します。

```ruby
require 'sabun/e2e'
config.middleware.insert_before 0, Sabun::E2E::Middleware
```

CLIとRails workerは、同じコミット・設定・宣言済み実行条件のGit checkoutを使ってください。workerは起動時のコミットとfingerprintを保持し、`record` / `run`が渡す識別情報との不一致を拒否します。Git情報がないサーバーや、古いworkerを使った計測は受け入れません。独自の設定パスを使う場合はworker起動前にも`SABUN_CONFIG_PATH`を設定してください。

Playwright側とRails側に共通の `SABUN_E2E_TOKEN` を設定し、Playwright側には次も設定します。

```bash
export SABUN_E2E_URL_TEMPLATE='http://127.0.0.1:31{parallelIndex}0'
export SABUN_E2E_JOBS_SYNC=1
```

`{parallelIndex}` はworkerのスロット番号へ置換されます。workerごとにRails・DB・cache・job環境を分離し、同一worker内でテストを同時実行しないでください。サーバーへ他のトラフィックを混ぜると、プロセス単位のCoverageが誤帰属します。

`record`時はRails workerが終了する際にも最終Coverageを収集します。Playwright workerごとのRails serverはsuite終了後に正常終了させてください。最終記録がないworkerは不完全としてbaselineへ昇格しません。各テスト間やPlaywrightの`afterAll`で実行されたRails処理の依存は、E2E suite共通の依存として各unitへ加えます。

**`SABUN_E2E_JOBS_SYNC=1` は必要なジョブがすべて同期的に完了することの宣言です。gemはジョブの完了を自動検証しません。** 非同期ジョブが残る環境では差分選択を有効化しないでください。tokenはテスト専用で、公開サーバーにこのmiddlewareを導入しないでください。

reporterは全テストのIDを記録し、bridgeが計測したテストと照合します。bridgeを使用しないテストが混在すると記録が不完全として拒否されます。

## 制限事項と安全性

- RSpecの標準Coverageは単一プロセス前提です。複数プロセスの並列RSpecや、Railsアプリが別プロセスで動くrequest specはそのままでは計測できません。
- Rubyのメソッド本体変更以外は原則全件実行します。callback・route・template・Factory・JS/CSSなどの構造・資産依存の細粒度選択は未実装です。
- E2EのJS/CSSソース→ビルド資産マッピングは未実装で、資産変更時は全件実行します。
- テスト間の共有状態・外部サービス・Feature Flag・キャッシュは完全に自動追跡できません。環境条件とデータ初期化の再現性が必要です。
- 品質ゲートはRails request specとChromiumのPlaywrightを対象にします。Capybara system spec、非同期ジョブ、他ブラウザーまで検証済みとは扱いません。導入先でも全件監査を継続してください。

## 開発・品質ゲート

```bash
bundle install
npm install --ignore-scripts --no-audit --no-fund
npx playwright install --with-deps chromium

bundle exec rake test:rails test:browser
node --test test/*.test.js
gem build sabun.gemspec
```

`test/fixtures/rails_app` を一時Gitリポジトリにコピーし、実ランナーでbaselineを生成します。価格・起動時の値・inlineジョブ・callback・ERB・JS/CSSを意図的に壊し、全件実行で失敗するexampleが差分実行でも同じように失敗することを検証します。無関係なテストを実際に省略することもassertするため、常時全件実行に戻すだけでは通りません。

CIにはRuby 3.2 / 3.3 / 3.4のrequest品質ゲートと、Ruby 3.3・Node 22・Chromiumのbrowser品質ゲートがあります。実行ログ・plan・JSON結果は`tmp/quality`とCI artifactに保存します。詳細と検証範囲は[品質ゲート](test/quality_scenarios.md)を参照してください。

設計と今後の細粒度化方針: [docs/design.md](docs/design.md)。
