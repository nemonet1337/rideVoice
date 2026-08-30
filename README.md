# rideVoice

rideVoice は、バイクツーリング中にライダー同士が通話するためのスマホアプリです。Android と iOS で動きます。通話は端末同士の P2P で、中身はエンドツーエンド暗号化されます。通話を中継する自前サーバはありません。

走り出す前に、その場で QR コードを読み合ってグループを作ります。同じ Wi-Fi やテザリングの上では LAN メッシュでつながります。各自が携帯回線のときは、公開 STUN だけの WebRTC でつなぎます（TURN サーバは使いません）。一度も近くで顔を合わせず、携帯だけで初対面の相手とつながることはできません。

一部の携帯網（IPv4 CGNAT 同士など）では P2P が失敗します。そのときはリード車のホットスポットに戻してください。

## 構成

言語は Flutter (Dart) だけです。

| 層 | 内容 |
|---|---|
| アプリ | Flutter（iOS + Android） |
| メッシュ | LAN オーバーレイ（UDP HELLO + AODV） |
| 暗号 | Dart（X25519 / HKDF-SHA256 / AES-256-GCM） |
| 音声 | 16 kHz PCM。Opus は `opus_dart` で後から載せる。ノイズ抑制は OS |

```
rideVoice/
  app/    Flutter アプリ
```

## 設計メモ

- 設計書 v2.1 との差分: [docs/DESIGN_DEVIATIONS.md](docs/DESIGN_DEVIATIONS.md)

## 開発

Flutter 3.x 以上。

```bash
cd app
flutter pub get
flutter test
```

## License

Proprietary. All rights reserved.
