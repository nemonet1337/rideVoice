# 設計書 v2.1 との差分・逸脱事項

設計書「バイクツーリング通話システム 設計書 v2.1」と実装の意図的な差分を記録する。
逸脱ではない未実装項目(ロードマップ上の将来フェーズ)は末尾に列挙する。

## 1. メッシュ transport:LAN オーバーレイ(設計書 §8 からの逸脱)

設計書 §8 は Android = Nearby Connections / iOS = MultipeerConnectivity を指定しているが、
実装は **mDNS/UDP ベースの LAN オーバーレイ**(`app/lib/transport/lan_transport.dart`)を採用する。

- 理由: iOS/Android 間に公式の直接相互接続 API が存在せず(設計書 §13 でも既知の課題)、
  共有 WiFi / テザリング上の UDP オーバーレイは両 OS で同一実装が使える。
- ルーティング(AODV)・バイナリパケット(§3-4)・E2E 暗号(§4)は
  `MeshTransport` インターフェースの上に transport 非依存で実装しており、
  将来 Nearby / Multipeer transport を追加しても上位層は変更不要。
- 発見は mDNS ではなく UDP ブロードキャスト HELLO で行う
  (`multicast_dns` パッケージはサービス広告非対応のため)。

## 2. パケットフォーマットの拡張(§3-4 への追加)

設計書 §3-4 のフィールドに加え、次の 2 フィールドを追加した
(`app/lib/mesh/packet.dart`):

| フィールド | サイズ | 理由 |
|-----------|------|------|
| packet_type | 1 byte(先頭) | 音声と AODV 制御(RREQ/RREP/RERR)・ハートビート・rekey の多重化に必須 |
| key_epoch | 4 bytes | GK ローテーション猶予期間(§13)中に新旧どちらの鍵で復号すべきかの判別に必須 |

また AES-GCM の AAD にはヘッダ先頭 24 バイト(type〜key_epoch)を使用するが、
**hop_count(TTL)は中継ノードが正当に減算するため AAD から除外**(ゼロ埋め)する。

## 3. WS シグナリングサーバー非実装(§10・§11 からの逸脱)

WebRTC のシグナリングは LiveKit が内包するため、独自の Gorilla WebSocket
シグナリングサーバーは実装しない(AGENTS.md の決定)。Go バックエンドは
REST(認証・ルーム・LiveKit ジョイントークン発行・ゲートウェイ登録)のみ提供する。

## 4. Bluetooth HFP(§11 からの逸脱)

`flutter_blue_plus` は使用せず、ヘッドセットへの HFP ルーティングは OS の
オーディオルーティングに委ねる(AGENTS.md の決定)。専用 BT Manager は未実装。

## 5. 暗号レイヤー:純 Dart 実装が現行(FFI は準備のみ)

設計書 §4-4 は Rust 暗号を Flutter FFI で利用するとしているが、FFI ブリッジは未接続。

- 現行実装: `app/lib/crypto/dart_crypto_provider.dart`(`package:cryptography`)。
  Rust `rv-crypto` と**パラメータ互換**(X25519 / HKDF-SHA256 info=`ridevoice-session-key` /
  AES-256-GCM, ciphertext||tag 形式, 送信者 ID 4B + カウンタ 8B の決定論的ノンス)。
  相互運用は固定テストベクタで両側から検証している
  (`rust/rv-crypto/src/seal.rs` / `app/test/crypto_test.dart`)。
- Rust 側は cdylib/staticlib 設定と flutter_rust_bridge 向けの平坦 API
  (`rust/rv-crypto/src/api.rs`)を用意済み。FFI 接続後は `CryptoProvider` の
  実装を差し替えるだけでよい。

### ノンス方式(§4-2 からの強化)

設計書はランダムノンスを指定するが、実装は**決定論的ノンス
(送信者 ID 4B + 単調カウンタ 8B)**を採用する。音声はフレームレートが高く
(50 packet/s/人)、ランダム 96bit ノンスは誕生日限界(約 2^32)で衝突リスクが
現実的になるため。ランダムノンス API も互換のため残している。

## 6. 匿名認証(開発段階の制限)

`POST /auth` は資格情報なしで 24 時間有効の JWT を発行する。これは開発段階の
プレースホルダであり、**本番投入前にデバイス登録ベースの認証に置き換えること**。
現状の緩和策: HS256 固定(alg confusion 対策)・`JWT_SECRET` 必須(未設定なら起動拒否)・
ルーム削除の作成者限定・LiveKit identity をトークンの sub に固定(なりすまし防止)。

## 7. 未実装(将来フェーズ、逸脱ではない)

- LiveKit クライアント統合(オンライン通話 UI・トラック管理)— Phase 1 残
- ハイブリッドモード / ゲートウェイノードの音声ブリッジ(§9)— Phase 6
- クラスタ間リレー(複数クラスタ構成)— Phase 5/6(単一クラスタ + AODV は実装済み)
- QR スキャン UI(`qr_flutter` / `mobile_scanner` の画面)— データ構造・検証は実装済み
- 状態別ヘッドセット音声通知(§7-1)
- Rust FFI ブリッジの codegen 接続(release.yml の cargo ビルド工程含む)
