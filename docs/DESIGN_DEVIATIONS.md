# 設計書 v2.1 との差分・逸脱事項

設計書「バイクツーリング通話システム 設計書 v2.1」と実装の意図的な差分を記録する。
逸脱ではない未実装項目(ロードマップ上の将来フェーズ)は末尾に列挙する。

## 1. メッシュ transport: LAN オーバーレイ(設計書 §8 からの逸脱)

設計書 §8 は Android = Nearby Connections / iOS = MultipeerConnectivity を指定しているが、
実装は **mDNS/UDP ベースの LAN オーバーレイ**(`app/lib/transport/lan_transport.dart`)を採用する。

- 理由: iOS/Android 間に公式の直接相互接続 API が存在せず(設計書 §13 でも既知の課題)、
  共有 WiFi / テザリング上の UDP オーバーレイは両 OS で同一実装が使える。
- ルーティング(AODV)・バイナリパケット(§3-4)・E2E 暗号(§4)は
  `MeshTransport` インターフェースの上に transport 非依存で実装しており、
  将来 WebRTC データチャネルを足しても上位層は変更不要。
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

## 3. 所有サーバを置かない(§9–§11 からの逸脱)

設計書のオンライン経路は LiveKit SFU + Go REST(認証・ルーム・ジョイントークン)だった。
本アプリは端末同士の P2P E2E であり、**バックエンドも Docker も持たない**。

- 同一 L2: 既存 LAN メッシュ
- 携帯網: 公開 STUN のみの WebRTC データチャネル(TURN なし)。シグナリングは
  LAN 制御パケットまたは近接時の QR / BLE。所有シグナリングサーバは作らない
- クラスタ間リレーやゲートウェイノード(§9)は、中継も端末が行う

IPv4 CGNAT 同士は STUN だけでは失敗しうる。その場合はリード車ホットスポットに戻す。

## 4. Bluetooth HFP(§11 からの逸脱)

`flutter_blue_plus` は使用せず、ヘッドセットへの HFP ルーティングは OS の
オーディオルーティングに委ねる。専用 BT Manager は未実装。

## 5. 暗号レイヤー: 純 Dart が本番

設計書 §4-4 は Rust 暗号を Flutter FFI で利用するとしているが、
E2E 暗号は `app/lib/crypto/dart_crypto_provider.dart`(`package:cryptography`)が唯一の実装。
リポジトリに Rust は置かない。

パラメータ: X25519 / HKDF-SHA256 info=`ridevoice-session-key` / AES-256-GCM
(ciphertext\|\|tag)、送信者 ID 4B + カウンタ 8B の決定論的ノンス。
固定テストベクタは `app/test/crypto_test.dart`。

音声: 設計書の Opus / RNNoise は、Opus を `opus_dart`(libopus C の FFI)で、
ノイズ抑制を OS の音声処理に任せる。現行パイプラインは PCM 素通し。

### ノンス方式(§4-2 からの強化)

設計書はランダムノンスを指定するが、実装は**決定論的ノンス
(送信者 ID 4B + 単調カウンタ 8B)**を採用する。音声はフレームレートが高く
(50 packet/s/人)、ランダム 96bit ノンスは誕生日限界(約 2^32)で衝突リスクが
現実的になるため。ランダムノンス API も互換のため残している。

## 6. 未実装(将来フェーズ、逸脱ではない)

- WebRTC データチャネル transport と近接 SDP 交換(BLE) — 携帯 P2P
- QR スキャン UI(`qr_flutter` / `mobile_scanner` の画面)— データ構造・検証は実装済み
- 状態別ヘッドセット音声通知(§7-1)
- Opus `FrameCodec`（`opus_dart`）
- クラスタ間リレー(複数クラスタ構成)— 単一クラスタ + AODV は実装済み
