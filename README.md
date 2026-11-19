# LockLyrics

入獄（非脱獄 / Sideload）環境の iOS 版 YouTube Music および汎用音楽アプリにインジェクトして動作する、**ロック画面リアルタイム歌詞表示ツイーク**（単体 `.dylib`）です。

ロック画面メディアプレイヤーのジャケット画像エリア（`MPMediaItemPropertyArtwork`）に、再生位置と同期したリアルタイム歌詞を描画して表示します。

## 主な特徴

- **完全依存ゼロ（非脱獄対応）**: Cydia Substrate や ElleKit に一切依存せず、Objective-C ランタイムの `__attribute__((constructor))` と Method Swizzling のみで動作します。
- **汎用設計**: アプリ固有の内部クラスを使わず、iOS 標準の `MPNowPlayingInfoCenter` のみをフックするため、YouTube Music をはじめ多くの音楽アプリで動作します（既存の `YTMusicUltimate` / `YTMusicPresence` 等とも競合しにくい設計です）。
- **LRCLIB 同期歌詞対応**: 無料・APIキー不要の [LRCLIB](https://lrclib.net/) API から同期歌詞（LRC）を非同期取得します（`/api/get` → 見つからない場合は `/api/search` で曲の長さが最も近い候補へフォールバック）。
- **省電力・省メモリ描画**:
  - ジャケットのぼかし背景（`CIGaussianBlur` + 暗色オーバーレイ）は**曲ごとに1回だけ生成してキャッシュ**。
  - 歌詞の行が切り替わったタイミングのみ `600×600` のアートワークを再描画。
  - 一時停止中（`playbackRate <= 0`）はタイマーを自動停止。
  - 同期歌詞が見つからない場合は元のジャケット画像をそのまま表示。

## ディレクトリ構成

```text
LockLyrics/
├── Makefile
├── README.md
├── .github/
│   └── workflows/
│       └── build.yml           # GitHub Actions 自動ビルド（Artifact出力）
└── src/
    ├── LLCommon.h              # ログマクロ・共通定数
    ├── LLLyricLine.h / .m      # 歌詞1行のデータモデル
    ├── LLLrcParser.h / .m      # LRC フォーマットパーサー
    ├── LLLrclibClient.h / .m   # LRCLIB API クライアント + メモリキャッシュ
    ├── LLArtworkRenderer.h/.m  # 背景ぼかしキャッシュ + 歌詞アートワーク描画
    ├── LLNowPlayingManager.h/.m# 再生位置算出・曲変更検知・同期タイマー制御
    └── LLTweakEntry.m          # constructor + MPNowPlayingInfoCenter Swizzling
```

## ビルド方法

### 方法 1: GitHub Actions で自動ビルド（おすすめ）

1. `LockLyrics/` フォルダの内容を GitHub リポジトリにプッシュします。
2. リポジトリの **Actions** タブから `Build LockLyrics (.dylib)` ワークフローの完了を待ちます。
3. 完了後、**Artifacts** セクションから `LockLyrics-dylib` をダウンロードし、`LockLyrics.dylib` を取り出します。

> ワークフロー内で `otool -L` による検証を行い、`CydiaSubstrate` / `ElleKit` へのリンクが含まれていないことも自動チェックします。

### 方法 2: ローカル環境（macOS + Theos）でビルド

```bash
export THEOS=~/theos
make FINALPACKAGE=1
```

ビルド成果物は `.theos/obj/LockLyrics.dylib` に生成されます。

## YouTube Music IPA へのインジェクト手順

### 方法 A: `cyan` を使う場合（CLI / 推奨）

[cyan](https://github.com/asdfzxcvbn/pyzule-rw) がインストールされている場合、以下のコマンドで IPA に `LockLyrics.dylib` を追加できます。

```bash
cyan -i YouTubeMusic_9.26.2_Presence_unsigned4.ipa \
     -o YouTubeMusic_9.26.2_LockLyrics.ipa \
     -f LockLyrics.dylib
```

生成された `.ipa` を AltStore / SideStore / LiveContainer / Sideloadly 等で署名・インストールしてください。

### 方法 B: `Sideloadly` を使う場合（Windows / macOS GUI）

1. **Sideloadly** を起動し、対象の IPA（例: `YouTubeMusic_9.26.2_Presence_unsigned4.ipa`）をドラッグ＆ドロップします。
2. **Advanced Options** を開きます。
3. **Tweak Injection** セクションで **Inject dylibs/frameworks** にチェックを入れ、`+ dylib/deb/bundle` ボタンから `LockLyrics.dylib` を追加します。
4. 必要に応じて Apple ID を入力し、**Start** をクリックしてデバイスにインストールします。

## デバッグログの確認

実行中は `NSLog` により `[LockLyrics]` プレフィックス付きで以下のイベントが出力されます（macOS の Console.app や `idevicesyslog` 等で確認可能）。

- 初期化完了 (`Initialized successfully...`)
- 曲変更 (`Track changed -> Title: ...`)
- LRCLIB 取得成功 / フォールバック / 失敗
- 歌詞行の切り替え (`Line switch [n/total]: ...`)
