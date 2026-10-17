# 品質ゲート

`test/fixtures/rails_app` は検証専用のRailsアプリです。公開用デモではなく、Minitestが一時ディレクトリへコピーして使うテストfixtureです。外部DB、認証情報、デプロイは不要です。

## 検証方法

実RSpecのrequest spec、実ChromiumのPlaywrightテストをCLI経由で全件実行し、baselineを生成します。依存マップをテスト側で手作りしたり、Rails・ブラウザー・Selectorをスタブに置き換えたりしません。

その後、fixtureのコードを一箇所ずつ変更して一時Gitリポジトリにコミットし、`plan` → `run` と元のテストランナーによる全件実行を比較します。本体のGit履歴や作業ファイルは変更しません。

変更後の全件実行が本当に失敗すること、差分実行が同じ失敗exampleをすべて検出すること、実際に実行したファイルがplanと一致することをassertします。価格変更では無関係な配送テストが省略されることも必須で、常時全件実行する実装では通りません。

## 必須シナリオ

| 変更・状態 | 実行する検証 |
| --- | --- |
| 既存メソッドの価格を壊す | request / browser双方で同じ失敗を捕捉し、無関係なテストを省略 |
| inline Active Jobの保存値を壊す | HTTP → job → SQLite → 画面の回帰を双方で検出 |
| 起動時に計算・保存する値を壊す | リクエスト中に再実行されないメソッドでも双方で検出 |
| `before_action`を追加する | 全件へ拡大し、認可で止まる画面を双方で検出 |
| ERBのタイトルを壊す | 全件へ拡大し、実際の描画失敗を双方で検出 |
| JSのDOM更新・CSSの表示を壊す | 実ブラウザーで回帰を検出 |
| 変更なし・未使用メソッドの無害な変更 | 差分実行を省略し、全件実行も成功する |
| Playwright 2 worker | Railsプロセス・URL・SQLite DBをworker単位に分離 |
| bridgeを使わないテストを追加 | 全テスト自体は成功しても、不完全なbaselineへの置換を拒否 |
| 初回失敗 → retry成功 | 実際のworker再起動を確認し、部分的な観測の昇格を拒否 |

reporterの引数契約とE2E起動依存には、修正前の不具合を再現する小さな回帰テストもあります。

## 実行

```bash
bundle install
npm install --ignore-scripts --no-audit --no-fund
npx playwright install --with-deps chromium

bundle exec rake test:rails test:browser
node --test test/*.test.js
```

Rails fixtureはRails 7.2系、Playwrightは1.56.1を使用します。GitHub ActionsではRuby 3.2 / 3.3 / 3.4でrequestの品質ゲート、Ruby 3.3とNode 22でbrowserの品質ゲートを実行します。依存パッケージ・ブラウザーがなければ失敗し、skipによって成功扱いにはしません。

`tmp/quality` に実行ログ、plan、実ランナーのJSON結果、worker起動情報を保存します。CIのartifactから、選択されたテストと見つかった失敗を確認できます。意図的に壊したケースの内部テストが失敗していても、それを外側の品質ゲートが期待どおり検出すればCIは成功します。

## 保証の境界

この有限のfixture群での回帰と省略を検証するもので、あらゆるアプリの検出率を保証するものではありません。非同期ジョブの完了追跡、複数サービス、共有外部キャッシュ、他ブラウザーはこのゲートの対象外です。Railsのrequest specとPlaywrightを直接検証し、Capybaraのsystem spec対応まで検証済みとは扱いません。
